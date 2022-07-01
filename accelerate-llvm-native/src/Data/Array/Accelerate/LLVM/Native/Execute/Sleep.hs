{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE MagicHash           #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE UnboxedTuples       #-}
-- |
-- Module      : Data.Array.Accelerate.LLVM.Native.Execute.Sleep
-- Copyright   : [2018..2020] The Accelerate Team
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <trevor.mcdonell@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.LLVM.Native.Execute.Sleep
  ( SleepScope, newSleepScope, sleepIf, wakeAll
  ) where

import Data.Atomics
import Data.IORef
import Control.Monad
import Control.Concurrent.MVar

newtype SleepScope = SleepScope (IORef State)

newSleepScope :: IO SleepScope
newSleepScope = do
  mvar <- newEmptyMVar
  SleepScope <$> newIORef (Busy mvar)

data State
  -- Some thread is waiting. The MVar is to be filled when new work is
  -- available.
  = Waiting {-# UNPACK #-} !(MVar ())
  -- All threads are busy. The MVar is currently not used (and is empty).
  -- It will be used when the state changes to waiting.
  | Busy    {-# UNPACK #-} !(MVar ())

-- Invariants:
--   * If the state is Waiting, then 'sleepIf' will not write to the state.
--   * If the state is Busy, then 'wakeAll' will not write to the state.
-- That will ensure that if a CAS fails, then it was interleaved by (at least)
-- another call to the same function.

sleepIf :: SleepScope -> IO (Bool) -> IO ()
sleepIf (SleepScope ref) condition = do
  ticket <- readForCAS ref
  case peekTicket ticket of
    Waiting mvar -> do
      -- Some thread is already waiting
      c <- condition
      if c then
        -- Start waiting
        readMVar mvar
      else
        -- Don't wait
        return ()
    Busy mvar -> do
      -- No thread is waiting yet
      c <- condition
      if c then do
        -- Change state to waiting
        _ <- casIORef ref ticket (Waiting mvar)
        -- If the CAS fails, then some other thread has written 'Waiting mvar'
        -- to the IORef. We thus can proceed without retrying.
        -- A CAS is needed, compared to a normal write, as this function can be
        -- interleaved by other threads doing 'sleepIf' and 'wakeAll'.
        -- Start waiting
        readMVar mvar
        -- readMVar is blocking until a value is available. All threads waiting
        -- will be woken when a value is written.
      else
        -- Don't wait
        return ()

wakeAll :: SleepScope -> IO ()
wakeAll (SleepScope ref) = do
  ticket <- readForCAS ref
  case peekTicket ticket of
    -- No need to wake anyone!
    Busy _ -> return ()
    Waiting mvar -> do
      new <- newEmptyMVar
      (success, _) <- casIORef ref ticket (Busy new)
      -- If the CAS fails, then some other thread has written 'Busy'
      -- to the IORef. We thus can proceed without retrying.
      -- A CAS is needed compared to a normal write, as this function can be
      -- interleaved by other threads doing 'wakeAll' and 'sleepIf'.

      -- Wake all threads
      when success $ putMVar mvar ()
