{-# LANGUAGE CPP                 #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}
{-# OPTIONS -fno-warn-orphans #-}
-- |
-- Module      : Data.Array.Accelerate.LLVM.PTX.Execute
-- Copyright   : [2014] Trevor L. McDonell, Sean Lee, Vinod Grover, NVIDIA Corporation
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@nvidia.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.LLVM.PTX.Execute (

  executeAcc, executeAfun1,

) where

-- accelerate
import Data.Array.Accelerate.Array.Sugar                        hiding ( allocateArray )
import qualified Data.Array.Accelerate.Array.Representation     as R

import Data.Array.Accelerate.LLVM.State
import Data.Array.Accelerate.LLVM.Execute

import Data.Array.Accelerate.LLVM.PTX.Array.Data
import Data.Array.Accelerate.LLVM.PTX.Execute.Async
import Data.Array.Accelerate.LLVM.PTX.Execute.Environment
import Data.Array.Accelerate.LLVM.PTX.Execute.Marshal
import Data.Array.Accelerate.LLVM.PTX.Target

import qualified Data.Array.Accelerate.LLVM.PTX.Debug           as Debug

-- cuda
import qualified Foreign.CUDA.Driver                            as CUDA

-- library
import Prelude                                                  hiding ( exp, map, scanl, scanr )
import Data.Int
import Control.Monad.Error
import Text.Printf
import qualified Prelude                                        as P

#include "accelerate.h"


-- Array expression evaluation
-- ---------------------------

-- Computations are evaluated by traversing the AST bottom up, and for each node
-- distinguishing between three cases:
--
--  1. If it is a Use node, we return a reference to the array data. The data
--     will already have been copied to the device during compilation of the
--     kernels.
--
--  2. If it is a non-skeleton node, such as a let binding or shape conversion,
--     then execute directly by updating the environment or similar.
--
--  3. If it is a skeleton node, then we need to execute the generated LLVM
--     code.
--
instance Execute PTX where
  map           = simpleOp
  generate      = simpleOp
  transform     = simpleOp
  backpermute   = simpleOp
  fold          = foldOp
  fold1         = fold1Op


-- Skeleton implementation
-- -----------------------

-- Simple kernels just need to know the shape of the output array
--
simpleOp
    :: (Shape sh, Elt e)
    => ExecutableR PTX
    -> Gamma aenv
    -> Aval aenv
    -> Stream
    -> sh
    -> LLVM PTX (Array sh e)
simpleOp kernel gamma aenv stream sh = do
  let ptx = case ptxKernel kernel of
              k:_ -> k
              _   -> INTERNAL_ERROR(error) "simpleOp" "kernel not found"
      n         = size sh
      start     = 0              :: Int32
      end       = fromIntegral n :: Int32
  --
  out <- allocateArray sh
  execute ptx gamma aenv stream n (start,end,out)
  return out


-- There are two flavours of fold operation:
--
--   1. If we are collapsing to a single value, then multiple thread blocks are
--      working together. Since thread blocks synchronise with each other via
--      kernel launches, each block computes a partial sum and the kernel is
--      launched recursively until the final value is reached.
--
--   2. If this is a multidimensional reduction, then each inner dimension is
--      handled by a single thread block, so no global communication is
--      necessary. Furthermore are two kernel flavours: each innermost dimension
--      can be cooperatively reduced by (a) a thread warp; or (b) a thread
--      block. Currently we always use the first, but require benchmarking to
--      determine when to select each.
--
fold1Op
    :: (Shape sh, Elt e)
    => ExecutableR PTX
    -> Gamma aenv
    -> Aval aenv
    -> Stream
    -> (sh :. Int)
    -> LLVM PTX (Array sh e)
fold1Op kernel gamma aenv stream sh@(_ :. sz)
  = BOUNDS_CHECK(check) "fold1" "empty array" (sz > 0)
  $ foldCore kernel gamma aenv stream sh

foldOp
    :: (Shape sh, Elt e)
    => ExecutableR PTX
    -> Gamma aenv
    -> Aval aenv
    -> Stream
    -> (sh :. Int)
    -> LLVM PTX (Array sh e)
foldOp kernel gamma aenv stream (sh :. sz)
  = foldCore kernel gamma aenv stream ((listToShape . P.map (max 1) . shapeToList $ sh) :. sz)

foldCore
    :: (Shape sh, Elt e)
    => ExecutableR PTX
    -> Gamma aenv
    -> Aval aenv
    -> Stream
    -> (sh :. Int)
    -> LLVM PTX (Array sh e)
foldCore kernel gamma aenv stream sh'@(sh :. _)
  | dim sh > 0      = simpleOp  kernel gamma aenv stream sh
  | otherwise       = foldAllOp kernel gamma aenv stream sh'

-- See note: [Marshalling foldAll output arrays]
--
foldAllOp
    :: forall aenv sh e. (Shape sh, Elt e)
    => ExecutableR PTX
    -> Gamma aenv
    -> Aval aenv
    -> Stream
    -> (sh :. Int)
    -> LLVM PTX (Array sh e)
foldAllOp kernel gamma aenv stream sh'
  | k1:k2:_ <- ptxKernel kernel
  = let
        foldIntro :: (sh :. Int) -> LLVM PTX (Array sh e)
        foldIntro (sh:.sz) = do
          let numElements       = size sh * sz
              numBlocks         = (kernelThreadBlocks k1) numElements
              start             = 0                        :: Int32
              end               = fromIntegral numElements :: Int32
          --
          out <- allocateArray (sh :. numBlocks)
          execute k1 gamma aenv stream numElements (start, end, out)
          foldRec out

        foldRec :: Array (sh :. Int) e -> LLVM PTX (Array sh e)
        foldRec out@(Array (sh,sz) adata) =
          let numElements       = R.size sh * sz
              numBlocks         = (kernelThreadBlocks k2) numElements
              start             = 0                        :: Int32
              end               = fromIntegral numElements :: Int32
          in if sz <= 1
                then do
                  -- We have recursed to a single block already. Trim the
                  -- intermediate working vector to the final scalar array.
                  return $! Array sh adata

                else do
                  -- Keep cooperatively reducing the output array in-place.
                  -- Note that we must continue to update the tracked size
                  -- so the recursion knows when to stop.
                  execute k2 gamma aenv stream numElements (start, end, out)
                  foldRec $! Array (sh,numBlocks) adata
    in
    foldIntro sh'

  | otherwise
  = INTERNAL_ERROR(error) "foldAllOp" "kernel not found"


-- Skeleton execution
-- ------------------

-- Execute the function implementing this kernel.
--
execute
    :: Marshalable args
    => Kernel
    -> Gamma aenv
    -> Aval aenv
    -> Stream
    -> Int
    -> args
    -> LLVM PTX ()
execute kernel gamma aenv stream n args =
  launch kernel stream n =<< marshal stream (args, (gamma,aenv))


-- Execute a device function with the given thread configuration and function
-- parameters.
--
launch :: Kernel -> Stream -> Int -> [CUDA.FunParam] -> LLVM PTX ()
launch Kernel{..} stream n args =
  liftIO $ Debug.timed Debug.dump_exec msg (Just stream)
         $ CUDA.launchKernel kernelFun grid cta smem (Just stream) args
  where
    cta         = (kernelThreadBlockSize, 1, 1)
    grid        = (kernelThreadBlocks n, 1, 1)
    smem        = kernelSharedMemBytes

    fst3 (x,_,_)         = x
    msg gpuTime wallTime =
      printf "exec: %s <<< %d, %d, %d >>> %s"
             kernelName (fst3 grid) (fst3 cta) smem (Debug.elapsed gpuTime wallTime)

