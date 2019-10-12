{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import           Control.Monad                  ( foldM
                                                , when
                                                )
import           Control.Exception.Safe         ( try
                                                , SomeException(..)
                                                )
import           Data.Proxy
import           Foreign.ForeignPtr
import           GHC.Generics
import           GHC.TypeLits
import           GHC.TypeLits.Extra
import           System.Environment
import           System.IO.Unsafe
import           System.Random

import qualified ATen.Cast                     as ATen
import qualified ATen.Class                    as ATen
import qualified ATen.Type                     as ATen
import qualified ATen.Managed.Type.Tensor      as ATen
import           Torch.Static
import           Torch.Static.Native     hiding ( linear )
import           Torch.Static.Factories
import           Torch.Static.NN
import qualified Torch.Autograd                as A
import qualified Torch.NN                      as A
import qualified Torch.DType                   as D
import qualified Torch.Tensor                  as D
import qualified Torch.Functions               as D
import qualified Torch.TensorFactories         as D
import qualified Image                         as I

--------------------------------------------------------------------------------
-- MLP for MNIST
--------------------------------------------------------------------------------

data MLPSpec (dtype :: D.DType) (inputFeatures :: Nat) (outputFeatures :: Nat) (hiddenFeatures0 :: Nat) (hiddenFeatures1 :: Nat) = MLPSpec Double

data MLP (dtype :: D.DType) (inputFeatures :: Nat) (outputFeatures :: Nat) (hiddenFeatures0 :: Nat) (hiddenFeatures1 :: Nat) =
  MLP { layer0 :: Linear dtype inputFeatures hiddenFeatures0
      , layer1 :: Linear dtype hiddenFeatures0 hiddenFeatures1
      , layer2 :: Linear dtype hiddenFeatures1 outputFeatures
      , dropout :: Dropout
      } deriving (Show, Generic)

instance A.Parameterized (MLP dtype inputFeatures outputFeatures hiddenFeatures0 hiddenFeatures1)

instance ( KnownDType dtype
         , KnownNat inputFeatures
         , KnownNat outputFeatures
         , KnownNat hiddenFeatures0
         , KnownNat hiddenFeatures1
         )
  => A.Randomizable (MLPSpec dtype inputFeatures outputFeatures hiddenFeatures0 hiddenFeatures1) (MLP dtype inputFeatures outputFeatures hiddenFeatures0 hiddenFeatures1)
 where
  sample (MLPSpec prob) = MLP <$> A.sample LinearSpec <*> A.sample LinearSpec <*> A.sample LinearSpec <*> A.sample (DropoutSpec prob)

mlp
  :: MLP dtype inputFeatures outputFeatures hiddenFeatures0 hiddenFeatures1
  -> Bool
  -> Tensor dtype '[batchSize, inputFeatures]
  -> IO (Tensor dtype '[batchSize, outputFeatures])
mlp MLP {..} train input =
  return
    .   linear layer2
    =<< Torch.Static.NN.dropout dropout train
    .   relu
    .   linear layer1
    =<< Torch.Static.NN.dropout dropout train
    .   relu
    .   linear layer0
    =<< pure input

foldLoop
  :: forall a b m . (Num a, Enum a, Monad m) => b -> a -> (b -> a -> m b) -> m b
foldLoop x count block = foldM block x ([1 .. count] :: [a])

type BatchSize = 256
type TestBatchSize = 1024
-- type HiddenFeatures0 = 4096
-- type HiddenFeatures1 = 2048
type HiddenFeatures0 = 32
type HiddenFeatures1 = 16

randomIndexes :: Int -> [Int]
randomIndexes size = (`mod` size) <$> randoms seed where seed = mkStdGen 123

toBackend
  :: forall t . (ATen.Castable t (ForeignPtr ATen.Tensor)) => String -> t -> t
toBackend backend t = unsafePerformIO $ case backend of
  "CUDA" -> ATen.cast1 ATen.tensor_cuda t
  _      -> ATen.cast1 ATen.tensor_cpu t

crossEntropyLoss
  :: forall batchSize outputFeatures
   . (KnownNat batchSize, KnownNat outputFeatures)
  => String
  -> Tensor 'D.Float '[batchSize, outputFeatures]
  -> Tensor 'D.Int64 '[batchSize]
  -> Tensor 'D.Float '[]
crossEntropyLoss backend result target =
  nll_loss @D.ReduceMean @ 'D.Float @batchSize @outputFeatures @'[]
    (logSoftmax @1 result)
    target
    (toBackend backend ones)
    (-100)

errorRate
  :: forall batchSize outputFeatures
   . (KnownNat batchSize, KnownNat outputFeatures)
  => Tensor 'D.Float '[batchSize, outputFeatures]
  -> Tensor 'D.Int64 '[batchSize]
  -> Tensor 'D.Float '[]
errorRate result target =
  let errorCount =
          toDType @D.Float . sumAll . ne (argmax @1 @DropDim result) $ target
  in  cmul errorCount ((1.0 /) . fromIntegral $ natValI @batchSize :: Double)

main = do
  debug'   <- try (getEnv "DEBUG") :: IO (Either SomeException String)
  backend' <- try (getEnv "BACKEND") :: IO (Either SomeException String)
  let backend = case backend' of
        Right "CUDA" -> "CUDA"
        _            -> "CPU"
      debug = case debug' of
        Right "TRUE" -> True
        _            -> False
      (numIters, printEvery) = (10000, 25)
      dropoutProb            = 0.2
  (trainingData, testData) <- I.initMnist
  init                     <- A.sample
    (MLPSpec @ 'D.Float @I.DataDim @I.ClassDim @HiddenFeatures0 @HiddenFeatures1
      dropoutProb
    )
  init' <- A.replaceParameters init <$> traverse
    (A.makeIndependent . toBackend backend . A.toDependent)
    (A.flattenParameters init)
  when debug $ print "init' is done."
  (trained, _) <-
    foldLoop (init', randomIndexes (I.length trainingData)) numIters
      $ \(state, idxs) i -> do
          let (indexes, nextIndexes) =
                (take (natValI @I.DataDim) idxs, drop (natValI @I.DataDim) idxs)
          (trainingLoss, _) <- computeLossAndErrorRate @BatchSize backend
                                                                  state
                                                                  True
                                                                  indexes
                                                                  trainingData
          let flat_parameters = A.flattenParameters state
          let gradients       = A.grad (toDynamic trainingLoss) flat_parameters
          when debug $ do
            print $ "last parameter:" ++ show (head . reverse $ flat_parameters)
            -- print $ "training loss:" ++ show trainingLoss
            -- print $ "gradients:" ++ show gradients
          when (i `mod` printEvery == 0)
            $ case someNatVal (fromIntegral $ I.length testData) of
                Just (SomeNat (Proxy :: Proxy testSize)) -> do
                  (testLoss, testError) <-
                    computeLossAndErrorRate @(Min TestBatchSize testSize)
                      backend
                      state
                      False
                      (randomIndexes (I.length testData))
                      testData
                  printLosses i trainingLoss testLoss testError
                _ -> print "Can not get the number of test"

          new_flat_parameters <- mapM A.makeIndependent
            $ A.sgd 1e-05 flat_parameters gradients
          return (A.replaceParameters state new_flat_parameters, nextIndexes)
  print trained
 where
  computeLossAndErrorRate
    :: forall n
     . (KnownNat n)
    => String
    -> MLP 'D.Float I.DataDim I.ClassDim HiddenFeatures0 HiddenFeatures1
    -> Bool
    -> [Int]
    -> I.MnistData
    -> IO (Tensor 'D.Float '[], Tensor 'D.Float '[])
  computeLossAndErrorRate backend state train indexes data' = do
    let input  = toBackend backend $ I.getImages @n data' indexes
        target = toBackend backend $ I.getLabels @n data' indexes
    result <- mlp state train input
    return (crossEntropyLoss backend result target, errorRate result target)
  printLosses i trainingLoss testLoss testError =
    let asFloat t = D.asValue . toDynamic . toCPU $ t :: Float
    in  putStrLn
          $  "Iteration: "
          <> show i
          <> ". Training batch loss: "
          <> show (asFloat trainingLoss)
          <> ". Test loss: "
          <> show (asFloat testLoss)
          <> ". Test error-rate: "
          <> show (asFloat testError)
