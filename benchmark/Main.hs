{-# LANGUAGE OverloadedStrings #-}

import Control.Monad
import System.Random
import Criterion.Main

import System.IO.RandomAccessFile

execute :: FileAccess a => AccessParams a -> FilePath -> Bool -> IO ()
execute params path doClose = do

  h <- initFile params path
  -- writeZeros h (1024*1024)

  replicateM_ 50 $ do
    offset <- randomRIO (100, 900*1024)
    writeData h offset "abdefgh0123456789"
    return ()

  replicateM_ 50 $ do
    offset <- randomRIO (100, 900*1024)
    readData h offset 512
    return ()

  when doClose $
    closeFile h

main :: IO ()
main = defaultMain [
    bench "simple" $ whnfIO $ execute SimpleParams "test.data" True
  , bench "threaded" $ whnfIO $ execute (ThreadedParams 4096) "test.data" True
  , bench "mmaped" $ whnfIO $ execute (MMapedParams 4096) "test.data" True
  , bench "cached/threaded" $ whnfIO $ execute (CachedBackend $ ThreadedParams 4096) "test.data" False
  , bench "cached/mmaped" $ whnfIO $ execute (CachedBackend $ MMapedParams 4096) "test.data" False
  ]