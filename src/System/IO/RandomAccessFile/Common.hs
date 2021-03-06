{-# LANGUAGE TypeFamilies #-}

module System.IO.RandomAccessFile.Common where

import Control.Monad
import Control.Concurrent
import Control.Concurrent.STM
import qualified Control.Concurrent.ReadWriteLock as RWL
import Control.Exception
import qualified Data.Map as M
import qualified Data.ByteString as B
import Data.List
import Data.Word

type Offset = Word64
type Size = Word64

class FileAccess a where
  data AccessParams a

  initFile :: AccessParams a -> FilePath -> IO a
  readBytes :: a -> Offset -> Size -> IO B.ByteString
  writeBytes :: a -> Offset -> B.ByteString -> IO ()

  currentFileSize :: a -> IO Size

  syncFile :: a -> IO ()
  syncFile _ = return ()

  closeFile :: a -> IO ()

writeZeros :: FileAccess a => a -> Size -> IO ()
writeZeros h size =
  writeBytes h 0 $ B.replicate (fromIntegral size) 0

data AccessType = ReadAccess | WriteAccess

type FileLocks = M.Map Offset RWL.RWLock

withQSem :: QSem -> IO a -> IO a
withQSem sem =
  bracket_ (waitQSem sem) (signalQSem sem)

withLock :: RWL.RWLock -> AccessType -> IO a -> IO a
withLock lock ReadAccess action =
  bracket_
    (RWL.acquireRead lock)
    (RWL.releaseRead lock)
    action
withLock lock WriteAccess action =
  bracket_
    (RWL.acquireWrite lock)
    (RWL.releaseWrite lock)
    action

withLocks :: [RWL.RWLock] -> AccessType -> IO a -> IO a
withLocks locks ReadAccess action =
  bracket_
    (forM_ locks RWL.acquireRead)
    (forM_ locks RWL.releaseRead)
    action
withLocks locks WriteAccess action =
  bracket_
    (forM_ locks RWL.acquireWrite)
    (forM_ locks RWL.releaseWrite)
    action

withLock_ :: Bool -> RWL.RWLock -> AccessType -> IO a -> IO a
withLock_ False _ _ action = action
withLock_ True lock access action = withLock lock access action

underBlockLock :: TVar FileLocks -> AccessType -> Offset -> IO a -> IO a
underBlockLock locksVar access n action = do
  newLock <- RWL.new
  lock <- atomically $ do
            locks <- readTVar locksVar
            case M.lookup n locks of
              Just lock -> return lock
              Nothing -> do
                writeTVar locksVar $ M.insert n newLock locks
                return newLock
  withLock lock access action

underBlockLocks :: TVar FileLocks -> AccessType -> [Offset] -> IO a -> IO a
underBlockLocks locksVar access ns action = do
  newLocks <- replicateM (length ns) RWL.new
  locks <- atomically $ do
            locks <- readTVar locksVar
            forM (zip [0..] $ sort ns) $ \(idx,n) ->
              case M.lookup n locks of
                Just lock -> return lock
                Nothing -> do
                  let newLock = newLocks !! idx
                  writeTVar locksVar $ M.insert n newLock locks
                  return newLock
  withLocks locks access action

