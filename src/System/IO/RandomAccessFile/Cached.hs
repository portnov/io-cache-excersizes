{-# LANGUAGE PackageImports #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module System.IO.RandomAccessFile.Cached
  (Cached (..),
   AccessParams (..),
   dfltCached
  ) where

import Control.Monad
import Control.Concurrent
import Control.Concurrent.STM
import qualified Control.Concurrent.ReadWriteLock as RWL
import qualified Data.Map as M
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import qualified Data.LruCache as LRU
import System.Posix.IO
import System.Directory
import Text.Printf

import System.IO.RandomAccessFile.Common

data Page = Page {pData :: L.ByteString, pLock :: RWL.RWLock}
  deriving (Eq)

instance Show Page where
  show p = "[Page]"

data CacheData = CacheData {
    cdDirty :: M.Map Offset Page
  , cdClean :: LRU.LruCache Offset Page
  }

type Cache = TVar CacheData

data Cached a = Cached {
    cBackend :: a
  , cCachePageSize :: Size
  , cCapacity :: Int
  , cCloseLock :: TVar Bool
  , cCache :: Cache
  }

lookupC :: Offset -> CacheData -> Maybe (Page, CacheData)
lookupC key c =
  case M.lookup key (cdDirty c) of
    Just page -> Just (page, c)
    Nothing -> case LRU.lookup key (cdClean c) of
                 Nothing -> Nothing
                 Just (page, lru') -> Just (page, c {cdClean = lru'})

putDirty :: Offset -> Page -> CacheData -> CacheData
putDirty key page c =
  c {cdDirty = M.insert key page (cdDirty c)}

putClean :: Offset -> Page -> CacheData -> CacheData
putClean key page c =
  c {cdClean = LRU.insert key page (cdClean c)}

markAllClean :: CacheData -> CacheData
markAllClean c = c {cdClean = update (cdClean c), cdDirty = M.empty}
  where
    update lru = foldr (uncurry LRU.insert) lru (M.assocs $ cdDirty c)

mkPage :: Size -> B.ByteString
mkPage sz = B.replicate (fromIntegral sz) 0

instance FileAccess a => FileAccess (Cached a) where
  data AccessParams (Cached a) =
    CachedBackend {
      backendParams :: AccessParams a
    , cachePageSize :: Size
    , cacheCapacity :: Int
    }

  initFile (CachedBackend params cachePageSize capacity) path = do
      ex <- doesFileExist path
      a <- initFile params path
      when (not ex) $ do
        writeBytes a 0 $ mkPage cachePageSize
        
      var <- atomically $ newTVar $ CacheData M.empty (LRU.empty capacity)
      let fileMode = Just 0o644
      let flags = defaultFileFlags
      closeLock <- newTVarIO False
      forkIO $ dumpQueue a closeLock var
      return $ Cached a cachePageSize capacity closeLock var
    where
      dumpQueue a closeLock var = do
--         threadDelay 10
        pages <- atomically $ do
                  cache <- readTVar var
                  let pages = M.assocs $ cdDirty cache
                      cache' = markAllClean cache
                  writeTVar var cache'
                  return pages
        if null pages
          then do
            canClose <- atomically $ readTVar closeLock
            if canClose
              then closeFile a
              else dumpQueue a closeLock var
          else do
            forM_ pages $ \(offset, page) -> do
                writeBytes a offset (L.toStrict $ pData page)
            -- syncFile a
            dumpQueue a closeLock var
  
  currentFileSize handle =
    currentFileSize (cBackend handle)
                      
  readBytes handle offset size = do
    let cachePageSize = cCachePageSize handle
        dataOffset0 = offset `mod` cachePageSize
        pageOffset0 = offset - dataOffset0
        dataOffset1 = (offset + size) `mod` cachePageSize
        pageOffset1 = (offset + size) - dataOffset1
        pageOffsets = [pageOffset0, pageOffset0 + cachePageSize .. pageOffset1]
        inputs = flip map pageOffsets $ \page ->
                  if page == pageOffset0
                    then (page, dataOffset0, min size (cachePageSize - dataOffset0))
                    else if page == pageOffset1
                           then (page, 0, dataOffset1)
                           else (page, 0, cachePageSize)
    -- printf "PO: %s\n" (show pageOffsets)
    -- printf "I: %s\n" (show inputs)
    fragments <- forM inputs $ \(pageOffset, dataOffset, sz) ->
                   readDataAligned handle pageOffset dataOffset sz
    return $ B.concat fragments
  
  writeBytes handle offset bstr = do
    let size = fromIntegral $ B.length bstr
        cachePageSize = cCachePageSize handle
        dataOffset0 = offset `mod` cachePageSize
        pageOffset0 = offset - dataOffset0
        dataOffset1 = (offset + size) `mod` cachePageSize
        pageOffset1 = (offset + size) - dataOffset1
        pageOffsets = [pageOffset0, pageOffset0 + cachePageSize .. pageOffset1]
        inputs = flip map pageOffsets $ \page ->
                  if page == pageOffset0
                    then (page, dataOffset0, min size (cachePageSize - dataOffset0))
                    else if page == pageOffset1
                           then (page, 0, dataOffset1)
                           else (page, 0, cachePageSize)
        fragments = flip map inputs $ \(pageOffset, dataOffset, sz) ->
                      let strOffset = pageOffset + dataOffset - offset
                          fragment = B.take (fromIntegral sz) $ B.drop (fromIntegral strOffset) bstr
                      in  (pageOffset, dataOffset, fragment)
    -- printf "PO: %s\n" (show pageOffsets)
    -- printf "I: %s\n" (show inputs)
    -- printf "F: %s\n" (show fragments)
    forM_ fragments $ \(pageOffset, dataOffset, fragment) ->
        writeDataAligned handle pageOffset dataOffset fragment

  syncFile handle = do
    syncFile (cBackend handle)

  closeFile handle = do
    atomically $ writeTVar (cCloseLock handle) True

readDataAligned :: FileAccess a => Cached a -> Offset -> Offset -> Size -> IO B.ByteString
readDataAligned handle pageOffset dataOffset size = do
  let a = cBackend handle
      var = cCache handle
      cachePageSize = cCachePageSize handle
  mbCached <- atomically $ do
    cache <- readTVar var
    return $ lookupC pageOffset cache
  case mbCached of
    Nothing -> do
      page <- readBytes a pageOffset cachePageSize
      let result = B.take (fromIntegral size) $ B.drop (fromIntegral dataOffset) page
      lock <- RWL.new
      atomically $ modifyTVar var $ \cache ->
        putClean pageOffset (Page (L.fromStrict page) lock) cache
      return result
    Just (page, cache') -> do
      withLock (pLock page) ReadAccess $ do
        atomically $ writeTVar var cache'
        let result = L.toStrict $ L.take (fromIntegral size) $ L.drop (fromIntegral dataOffset) $ pData page
        return result

writeDataAligned :: FileAccess a => Cached a -> Offset -> Offset -> B.ByteString -> IO ()
writeDataAligned handle pageOffset dataOffset bstr = do
  -- printf "WA: page %d, data %d, len %d\n" pageOffset dataOffset (B.length bstr)
  fsize <- currentFileSize handle
  let a = cBackend handle
      var = cCache handle
      cachePageSize = cCachePageSize handle
      size = fromIntegral $ B.length bstr
  mbCached <- atomically $ do
    cache <- readTVar var
    return $ lookupC pageOffset cache
  case mbCached of
    Nothing -> do
      page <- if (pageOffset + dataOffset + size) >= fsize
                then return $ mkPage cachePageSize
                else readBytes a pageOffset cachePageSize
      let lazyPage = L.fromStrict page
          lazyBstr = L.fromStrict bstr
      let page' = L.take (fromIntegral dataOffset) lazyPage `L.append`
                   lazyBstr `L.append`
                   L.drop (fromIntegral dataOffset + L.length lazyBstr) lazyPage
      when (fromIntegral (B.length page) /= L.length page') $
        fail $ printf "W/N: %d /= %d! data: %d, page: %d, len: %d" (B.length page) (L.length page') pageOffset dataOffset (B.length bstr)
      lock <- RWL.new
      atomically $ modifyTVar var $ \cache ->
        putDirty pageOffset (Page page' lock) cache

    Just (page, cache') -> do
      withLock (pLock page) WriteAccess $ do
        let pageData = pData page
            lazyBstr = L.fromStrict bstr
        let pageData' = L.take (fromIntegral dataOffset) pageData `L.append` lazyBstr `L.append` L.drop (fromIntegral dataOffset + L.length lazyBstr) pageData
        let page' = page {pData = pageData'}
        when (L.length pageData /= L.length pageData') $
          fail $ printf "W/J: %d /= %d!" (L.length pageData) (L.length pageData')
        atomically $ modifyTVar var $ \cache ->
          putDirty pageOffset page' cache

dfltCached :: FileAccess a => AccessParams a -> AccessParams (Cached a)
dfltCached params = CachedBackend params 4096 100

