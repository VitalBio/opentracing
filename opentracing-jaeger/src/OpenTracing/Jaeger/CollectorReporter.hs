{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns    #-}

module OpenTracing.Jaeger.CollectorReporter
    ( Env
    , newEnv
    , closeEnv
    , withEnv

    , CollectorAddr(..)
    , defaultCollectorAddr

    , jaegerCollectorReporter
    )
where

import           Control.Monad             (void)
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Data.Monoid
import           Data.Text                 (Text)
import           Data.Vector               (fromList)
import qualified Jaeger_Types              as Thrift
import           Network                   (HostName)
import           Network.HTTP.Client
import           OpenTracing.Jaeger.Thrift
import           OpenTracing.Reporting
import           OpenTracing.Span
import           OpenTracing.Tags
import           OpenTracing.Types
import           Thrift.Protocol.Binary
import           Thrift.Transport.Empty


type Env = BatchEnv

data CollectorAddr = CollectorAddr
    { collectorHost :: HostName
    , collectorPort :: Port
    }

defaultCollectorAddr :: CollectorAddr
defaultCollectorAddr = CollectorAddr
    { collectorHost = "127.0.0.1"
    , collectorPort = 14268
    }

-- XXX: support https
newEnv :: Text -> Tags -> CollectorAddr -> IO Env
newEnv srv tags CollectorAddr{..} = do
    rq  <- parseRequest $ "POST http://"
               <> collectorHost <> ":" <> show collectorPort
               <> "/api/traces?format=jaeger.thrift"
    mgr <- newManager defaultManagerSettings
    newBatchEnv 100 (reporter rq mgr (toThriftProcess srv tags))

closeEnv :: Env -> IO ()
closeEnv = closeBatchEnv

withEnv
    :: ( MonadIO   m
       , MonadMask m
       )
    => Text
    -> Tags
    -> CollectorAddr
    -> (Env -> m a)
    -> m a
withEnv srv tags addr =
    bracket (liftIO $ newEnv srv tags addr) (liftIO . closeEnv)


jaegerCollectorReporter :: MonadIO m => Env -> FinishedSpan -> m ()
jaegerCollectorReporter = batchReporter


reporter :: Request -> Manager -> Thrift.Process -> [FinishedSpan] -> IO ()
reporter rq mgr proc (fromList -> spans) =
    void $ httpLbs rq { requestBody = body } mgr -- XXX: check response status
  where
    body = RequestBodyLBS . serializeBatch $ toThriftBatch proc spans

    -- nb. collector accepts 'BinaryProtocol', but agent 'CompactProtocol'
    serializeBatch = Thrift.encode_Batch (BinaryProtocol EmptyTransport)
