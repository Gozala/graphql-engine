module Hasura.Server.Metrics
  ( ServerMetricsSpec (..)
  , ServerMetrics (..)
  , createServerMetrics
  ) where

import           Data.Kind                   (Type)
import           GHC.TypeLits                (Symbol)
import           System.Metrics
import           System.Metrics.Distribution (Distribution)
import           System.Metrics.Gauge        (Gauge)

import           Hasura.Prelude

-- | A specification of the metrics tracked by the server.
--
-- The use of the "unit" type () for the "tag structure" type parameter of a
-- metric indicates that we prohibit that metric from being annotated with
-- tags.
data ServerMetricsSpec
  :: Symbol -- Metric name
  -> MetricType -- Metric type, e.g. Counter, Gauge
  -> Type -- Tag structure
  -> Type
  where
  -- | Current Number of active Warp threads
  WarpThreads :: ServerMetricsSpec
    "warp_threads" 'GaugeType ()
  -- | Current number of active websocket connections
  WebsocketConnections :: ServerMetricsSpec
    "websocket_connections" 'GaugeType ()
  -- | Current number of active subscriptions
  ActiveSubscriptions :: ServerMetricsSpec
    "active_subscriptions" 'GaugeType ()
  -- | Total Number of events fetched from last 'Event Trigger Fetch'
  NumEventsFetchedPerBatch :: ServerMetricsSpec
    "events_fetched_per_batch" 'DistributionType ()
  -- | Current number of Event trigger's HTTP workers in process
  NumEventHTTPWorkers :: ServerMetricsSpec
    "num_event_trigger_http_workers" 'GaugeType ()
  -- | Time (in seconds) between the 'Event Trigger Fetch' from DB and the
  -- processing of the event
  EventQueueTime :: ServerMetricsSpec
    "event_queue_time" 'DistributionType ()

-- | Mutable references for the server metrics. See `ServerMetricsSpec` for a
-- description of each metric.
data ServerMetrics
  = ServerMetrics
  { smWarpThreads              :: !Gauge
  , smWebsocketConnections     :: !Gauge
  , smActiveSubscriptions      :: !Gauge
  , smNumEventsFetchedPerBatch :: !Distribution
  , smNumEventHTTPWorkers      :: !Gauge
  , smEventQueueTime           :: !Distribution
  }

createServerMetrics :: Store ServerMetricsSpec -> IO ServerMetrics
createServerMetrics store = do
  smWarpThreads <- createGauge WarpThreads () store
  smWebsocketConnections <- createGauge WebsocketConnections () store
  smActiveSubscriptions <- createGauge ActiveSubscriptions () store
  smNumEventsFetchedPerBatch <- createDistribution NumEventsFetchedPerBatch () store
  smNumEventHTTPWorkers <- createGauge NumEventHTTPWorkers () store
  smEventQueueTime <- createDistribution EventQueueTime () store
  pure ServerMetrics { .. }
