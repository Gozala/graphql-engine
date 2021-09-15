{-|
= Scheduled Triggers

This module implements the functionality of invoking webhooks during specified
time events aka scheduled events. The scheduled events are the events generated
by the graphql-engine using the cron triggers or/and a scheduled event can
be created by the user at a specified time with the payload, webhook, headers
and the retry configuration. Scheduled events are modeled using rows in Postgres
with a @timestamp@ column.

This module implements scheduling and delivery of scheduled
events:

1. Scheduling a cron event involves creating new cron events. New
cron events are created based on the cron schedule and the number of
scheduled events that are already present in the scheduled events buffer.
The graphql-engine computes the new scheduled events and writes them to
the database.(Generator)

2. Delivering a scheduled event involves reading undelivered scheduled events
from the database and delivering them to the webhook server. (Processor)

The rationale behind separating the event scheduling and event delivery
mechanism into two different threads is that the scheduling and delivering of
the scheduled events are not directly dependent on each other. The generator
will almost always try to create scheduled events which are supposed to be
delivered in the future (timestamp > current_timestamp) and the processor
will fetch scheduled events of the past (timestamp < current_timestamp). So,
the set of the scheduled events generated by the generator and the processor
will never be the same. The point here is that they're not correlated to each
other. They can be split into different threads for a better performance.

== Implementation

The scheduled triggers eventing is being implemented in the metadata storage.
All functions that make interaction to storage system are abstracted in
the @'MonadMetadataStorage' class.

During the startup, two threads are started:

1. Generator: Fetches the list of scheduled triggers from cache and generates
   the scheduled events.

    - Additional events will be generated only if there are fewer than 100
      scheduled events.

    - The upcoming events timestamp will be generated using:

        - cron schedule of the scheduled trigger

        - max timestamp of the scheduled events that already exist or
          current_timestamp(when no scheduled events exist)

        - The timestamp of the scheduled events is stored with timezone because
          `SELECT NOW()` returns timestamp with timezone, so it's good to
          compare two things of the same type.

    This effectively corresponds to doing an INSERT with values containing
    specific timestamp.

2. Processor: Fetches the undelivered cron events and the scheduled events
   from the database and which have timestamp lesser than the
   current timestamp and then process them.

TODO
- Consider and document ordering guarantees
  - do we have any in the presence of multiple hasura instances?
- If we have nothing useful to say about ordering, then consider processing
  events asynchronously, so that a slow webhook doesn't cause everything
  subsequent to be delayed

-}
module Hasura.Eventing.ScheduledTrigger
  ( runCronEventsGenerator
  , processScheduledTriggers
  , generateScheduleTimes

  , CronEventSeed(..)
  , LockedEventsCtx(..)

  -- * Database interactions
  -- Following function names are similar to those present in
  -- 'MonadMetadataStorage' type class. To avoid duplication,
  -- 'Tx' is suffixed to identify as database transactions
  , getDeprivedCronTriggerStatsTx
  , getScheduledEventsForDeliveryTx
  , insertInvocationTx
  , setScheduledEventOpTx
  , unlockScheduledEventsTx
  , unlockAllLockedScheduledEventsTx
  , insertCronEventsTx
  , insertOneOffScheduledEventTx
  , dropFutureCronEventsTx
  , getOneOffScheduledEventsTx
  , getCronEventsTx
  , deleteScheduledEventTx
  , getInvocationsTx
  , getInvocationsQuery
  , getInvocationsQueryNoPagination

  -- * Export utility functions which are useful to build
  -- SQLs for fetching data from metadata storage
  , mkScheduledEventStatusFilter
  , scheduledTimeOrderBy
  , mkPaginationSelectExp
  , withCount
  , invocationFieldExtractors
  , mkEventIdBoolExp
  , EventTables (..)
  ) where

import           Hasura.Prelude

import qualified Data.Aeson                             as J
import qualified Data.ByteString.Lazy                   as BL
import qualified Data.Environment                       as Env
import qualified Data.HashMap.Strict                    as Map
import qualified Data.List.NonEmpty                     as NE
import qualified Data.Set                               as Set
import qualified Data.TByteString                       as TBS
import qualified Data.Text                              as T
import qualified Database.PG.Query                      as Q
import qualified Network.HTTP.Client                    as HTTP
import qualified Text.Builder                           as TB

import           Control.Arrow.Extended                 (dup)
import           Control.Concurrent.Extended            (Forever (..), sleep)
import           Control.Concurrent.STM
import           Data.Has
import           Data.Int                               (Int64)
import           Data.List                              (unfoldr)
import           Data.Time.Clock
import           System.Cron

import qualified Hasura.Backends.Postgres.SQL.DML       as S
import qualified Hasura.Logging                         as L
import qualified Hasura.Tracing                         as Tracing

import           Hasura.Backends.Postgres.SQL.Types
import           Hasura.Base.Error
import           Hasura.Eventing.Common
import           Hasura.Eventing.HTTP
import           Hasura.Eventing.ScheduledTrigger.Types
import           Hasura.Metadata.Class
import           Hasura.RQL.DDL.EventTrigger            (getHeaderInfosFromConf)
import           Hasura.RQL.DDL.Headers
import           Hasura.RQL.Types
import           Hasura.SQL.Types
import           Hasura.Server.Version                  (HasVersion)


-- | runCronEventsGenerator makes sure that all the cron triggers
--   have an adequate buffer of cron events.
runCronEventsGenerator
  :: ( MonadIO m
     , MonadMetadataStorage (MetadataStorageT m)
     )
  => L.Logger L.Hasura
  -> IO SchemaCache
  -> m void
runCronEventsGenerator logger getSC = do
  forever $ do
    sc <- liftIO getSC
    -- get cron triggers from cache
    let cronTriggersCache = scCronTriggers sc

    unless (Map.null cronTriggersCache) $ do
      -- Poll the DB only when there's at-least one cron trigger present
      -- in the schema cache
      -- get cron trigger stats from db
      -- When shutdown is initiated, we stop generating new cron events
      eitherRes <- runMetadataStorageT $ do
        deprivedCronTriggerStats <- getDeprivedCronTriggerStats $ Map.keys cronTriggersCache
        -- join stats with cron triggers and produce @[(CronTriggerInfo, CronTriggerStats)]@
        cronTriggersForHydrationWithStats <-
          catMaybes <$>
          mapM (withCronTrigger cronTriggersCache) deprivedCronTriggerStats
        insertCronEventsFor cronTriggersForHydrationWithStats

      onLeft eitherRes $ L.unLogger logger .
        ScheduledTriggerInternalErr . err500 Unexpected . tshow

    -- See discussion: https://github.com/hasura/graphql-engine-mono/issues/1001
    liftIO $ sleep (minutes 1)
    where
      withCronTrigger cronTriggerCache cronTriggerStat = do
        case Map.lookup (ctsName cronTriggerStat) cronTriggerCache of
          Nothing -> do
            L.unLogger logger $
              ScheduledTriggerInternalErr $
                err500 Unexpected "could not find scheduled trigger in the schema cache"
            pure Nothing
          Just cronTrigger -> pure $
            Just (cronTrigger, cronTriggerStat)

insertCronEventsFor
  :: (MonadMetadataStorage m)
  => [(CronTriggerInfo, CronTriggerStats)]
  -> m ()
insertCronEventsFor cronTriggersWithStats = do
  let scheduledEvents = flip concatMap cronTriggersWithStats $ \(cti, stats) ->
        generateCronEventsFrom (ctsMaxScheduledTime stats) cti
  case scheduledEvents of
    []     -> pure ()
    events -> insertCronEvents events

generateCronEventsFrom :: UTCTime -> CronTriggerInfo-> [CronEventSeed]
generateCronEventsFrom startTime CronTriggerInfo{..} =
  map (CronEventSeed ctiName) $
      -- generate next 100 events; see getDeprivedCronTriggerStatsTx:
      generateScheduleTimes startTime 100 ctiSchedule

-- | Generates next @n events starting @from according to 'CronSchedule'
generateScheduleTimes :: UTCTime -> Int -> CronSchedule -> [UTCTime]
generateScheduleTimes from n cron = take n $ go from
  where
    go = unfoldr (fmap dup . nextMatch cron)

processCronEvents
  :: ( HasVersion
     , MonadIO m
     , Tracing.HasReporter m
     , MonadMetadataStorage (MetadataStorageT m)
     )
  => L.Logger L.Hasura
  -> LogBehavior
  -> HTTP.Manager
  -> [CronEvent]
  -> IO SchemaCache
  -> TVar (Set.Set CronEventId)
  -> m ()
processCronEvents logger logBehavior httpMgr cronEvents getSC lockedCronEvents = do
  cronTriggersInfo <- scCronTriggers <$> liftIO getSC
  -- save the locked cron events that have been fetched from the
  -- database, the events stored here will be unlocked in case a
  -- graceful shutdown is initiated in midst of processing these events
  saveLockedEvents (map _ceId cronEvents) lockedCronEvents
  -- The `createdAt` of a cron event is the `created_at` of the cron trigger
  for_ cronEvents $ \(CronEvent id' name st _ tries _ _)-> do
    case Map.lookup name cronTriggersInfo of
      Nothing ->  logInternalError $
        err500 Unexpected "could not find cron trigger in cache"
      Just CronTriggerInfo{..} -> do
        let webhookUrl = unResolvedWebhook ctiWebhookInfo
            payload = ScheduledEventWebhookPayload id' (Just name) st
                      (fromMaybe J.Null ctiPayload) ctiComment
                      Nothing
            retryCtx = RetryContext tries ctiRetryConf
        finally <- runMetadataStorageT $ flip runReaderT (logger, httpMgr) $
                   processScheduledEvent logBehavior id' ctiHeaders retryCtx
                                         payload webhookUrl Cron
        removeEventFromLockedEvents id' lockedCronEvents
        onLeft finally logInternalError
  where
    logInternalError err = liftIO . L.unLogger logger $ ScheduledTriggerInternalErr err

processOneOffScheduledEvents
  :: ( HasVersion
     , MonadIO m
     , Tracing.HasReporter m
     , MonadMetadataStorage (MetadataStorageT m)
     )
  => Env.Environment
  -> L.Logger L.Hasura
  -> LogBehavior
  -> HTTP.Manager
  -> [OneOffScheduledEvent]
  -> TVar (Set.Set OneOffScheduledEventId)
  -> m ()
processOneOffScheduledEvents env logger logBehavior httpMgr
                             oneOffEvents lockedOneOffScheduledEvents = do
  -- save the locked one-off events that have been fetched from the
  -- database, the events stored here will be unlocked in case a
  -- graceful shutdown is initiated in midst of processing these events
  saveLockedEvents (map _ooseId oneOffEvents) lockedOneOffScheduledEvents
  for_ oneOffEvents $ \OneOffScheduledEvent{..} -> do
    (either logInternalError pure) =<< runMetadataStorageT do
      webhookInfo <- resolveWebhook env _ooseWebhookConf
      headerInfo <- getHeaderInfosFromConf env _ooseHeaderConf
      let webhookUrl = unResolvedWebhook webhookInfo
          payload = ScheduledEventWebhookPayload _ooseId Nothing
                    _ooseScheduledTime (fromMaybe J.Null _oosePayload)
                    _ooseComment (Just _ooseCreatedAt)
          retryCtx = RetryContext _ooseTries _ooseRetryConf

      flip runReaderT (logger, httpMgr) $
        processScheduledEvent logBehavior _ooseId headerInfo retryCtx payload webhookUrl OneOff
      removeEventFromLockedEvents _ooseId lockedOneOffScheduledEvents
  where
    logInternalError err = liftIO . L.unLogger logger $ ScheduledTriggerInternalErr err

processScheduledTriggers
  :: ( HasVersion
     , MonadIO m
     , Tracing.HasReporter m
     , MonadMetadataStorage (MetadataStorageT m)
     )
  => Env.Environment
  -> L.Logger L.Hasura
  -> LogBehavior
  -> HTTP.Manager
  -> IO SchemaCache
  -> LockedEventsCtx
  -> m (Forever m)
processScheduledTriggers env logger logBehavior httpMgr getSC LockedEventsCtx {..} = do
  return $ Forever () $ const $ do
    result <- runMetadataStorageT getScheduledEventsForDelivery
    case result of
      Left e -> logInternalError e
      Right (cronEvents, oneOffEvents) -> do
        processCronEvents logger logBehavior httpMgr cronEvents getSC leCronEvents
        processOneOffScheduledEvents env logger logBehavior httpMgr oneOffEvents leOneOffEvents
        -- NOTE: cron events are scheduled at times with minute resolution (as on
        -- unix), while one-off events can be set for arbitrary times. The sleep
        -- time here determines how overdue a scheduled event (cron or one-off)
        -- might be before we begin processing:
    liftIO $ sleep (seconds 10)
  where
    logInternalError err = liftIO . L.unLogger logger $ ScheduledTriggerInternalErr err

processScheduledEvent
  :: ( MonadReader r m
     , Has HTTP.Manager r
     , Has (L.Logger L.Hasura) r
     , HasVersion
     , MonadIO m
     , Tracing.HasReporter m
     , MonadMetadataStorage m
     )
  => LogBehavior
  -> ScheduledEventId
  -> [EventHeaderInfo]
  -> RetryContext
  -> ScheduledEventWebhookPayload
  -> Text
  -> ScheduledEventType
  -> m ()
processScheduledEvent logBehavior eventId eventHeaders retryCtx payload webhookUrl type'
                      = Tracing.runTraceT traceNote do
  currentTime <- liftIO getCurrentTime
  let retryConf = _rctxConf retryCtx
      scheduledTime = sewpScheduledTime payload
  if convertDuration (diffUTCTime currentTime scheduledTime)
    > unNonNegativeDiffTime (strcToleranceSeconds retryConf)
    then processDead eventId type'
    else do
      let timeoutSeconds = round $ unNonNegativeDiffTime
                             $ strcTimeoutSeconds retryConf
          httpTimeout = HTTP.responseTimeoutMicro (timeoutSeconds * 1000000)
          (headers, decodedHeaders) = prepareHeaders logBehavior eventHeaders
          extraLogCtx = ExtraLogContext eventId (sewpName payload)
          webhookReqBodyJson = J.toJSON payload
          webhookReqBody = J.encode webhookReqBodyJson
          requestDetails = RequestDetails $ BL.length webhookReqBody
      eitherRes <- runExceptT $ tryWebhook headers httpTimeout webhookReqBody (T.unpack webhookUrl)
      logHTTPForST eitherRes extraLogCtx requestDetails logBehavior
      case eitherRes of
        Left e  -> processError eventId retryCtx decodedHeaders type' webhookReqBodyJson e
        Right r -> processSuccess eventId decodedHeaders type' webhookReqBodyJson r
  where
    traceNote = "Scheduled trigger" <> foldMap ((": " <>) . triggerNameToTxt) (sewpName payload)

processError
  :: ( MonadIO m
     , MonadMetadataStorage m
     )
  => ScheduledEventId
  -> RetryContext
  -> [HeaderConf]
  -> ScheduledEventType
  -> J.Value
  -> HTTPErr a
  -> m ()
processError eventId retryCtx decodedHeaders type' reqJson err = do
  let invocation = case err of
        HClient excp -> do
          let errMsg = TBS.fromLBS $ J.encode $ show excp
          mkInvocation eventId 1000 decodedHeaders errMsg [] reqJson
        HParse _ detail -> do
          let errMsg = TBS.fromLBS $ J.encode detail
          mkInvocation eventId 1001 decodedHeaders errMsg [] reqJson
        HStatus errResp -> do
          let respPayload = hrsBody errResp
              respHeaders = hrsHeaders errResp
              respStatus = hrsStatus errResp
          mkInvocation eventId respStatus decodedHeaders respPayload respHeaders reqJson
        HOther detail -> do
          let errMsg = (TBS.fromLBS $ J.encode detail)
          mkInvocation eventId 500 decodedHeaders errMsg [] reqJson
  insertScheduledEventInvocation invocation type'
  retryOrMarkError eventId retryCtx err type'

retryOrMarkError
  :: (MonadIO m, MonadMetadataStorage m)
  => ScheduledEventId
  -> RetryContext
  -> HTTPErr a
  -> ScheduledEventType
  -> m ()
retryOrMarkError eventId retryCtx err type' = do
  let RetryContext tries retryConf = retryCtx
      mRetryHeader = getRetryAfterHeaderFromHTTPErr err
      mRetryHeaderSeconds = parseRetryHeaderValue =<< mRetryHeader
      triesExhausted = tries >= strcNumRetries retryConf
      noRetryHeader = isNothing mRetryHeaderSeconds
  if triesExhausted && noRetryHeader
    then
      setScheduledEventOp eventId (SEOpStatus SESError) type'
    else do
      currentTime <- liftIO getCurrentTime
      let delay = fromMaybe (round $ unNonNegativeDiffTime
                             $ strcRetryIntervalSeconds retryConf)
                    mRetryHeaderSeconds
          diff = fromIntegral delay
          retryTime = addUTCTime diff currentTime
      setScheduledEventOp eventId (SEOpRetry retryTime) type'

{- Note [Scheduled event lifecycle]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Scheduled events move between six different states over the course of their
lifetime, as represented by the following flowchart:
  ┌───────────┐      ┌────────┐      ┌───────────┐
  │ scheduled │─(a)─→│ locked │─(b)─→│ delivered │
  └───────────┘      └────────┘      └───────────┘
          ↑              │           ┌───────┐
          └────(c)───────┼─────(d)──→│ error │
                         │           └───────┘
                         │           ┌──────┐
                         └─────(e)──→│ dead │
                                     └──────┘

When a scheduled event is first created, it starts in the 'scheduled' state,
and it can transition to other states in the following ways:
  a. When graphql-engine fetches a scheduled event from the database to process
     it, it sets its state to 'locked'. This prevents multiple graphql-engine
     instances running on the same database from processing the same
     scheduled event concurrently.
  b. When a scheduled event is processed successfully, it is marked 'delivered'.
  c. If a scheduled event fails to be processed, but it hasn’t yet reached
     its maximum retry limit, its retry counter is incremented and
     it is returned to the 'scheduled' state.
  d. If a scheduled event fails to be processed and *has* reached its
     retry limit, its state is set to 'error'.
  e. If for whatever reason the difference between the current time and the
     scheduled time is greater than the tolerance of the scheduled event, it
     will not be processed and its state will be set to 'dead'.
-}

processSuccess
  :: (MonadMetadataStorage m)
  => ScheduledEventId
  -> [HeaderConf]
  -> ScheduledEventType
  -> J.Value
  -> HTTPResp a
  -> m ()
processSuccess eventId decodedHeaders type' reqBodyJson resp = do
  let respBody = hrsBody resp
      respHeaders = hrsHeaders resp
      respStatus = hrsStatus resp
      invocation = mkInvocation eventId respStatus decodedHeaders respBody respHeaders reqBodyJson
  insertScheduledEventInvocation invocation type'
  setScheduledEventOp eventId (SEOpStatus SESDelivered) type'

processDead
  :: (MonadMetadataStorage m)
  => ScheduledEventId -> ScheduledEventType -> m ()
processDead eventId type' =
  setScheduledEventOp eventId (SEOpStatus SESDead) type'

mkInvocation
  :: ScheduledEventId
  -> Int
  -> [HeaderConf]
  -> TBS.TByteString
  -> [HeaderConf]
  -> J.Value
  -> (Invocation 'ScheduledType)
mkInvocation eventId status reqHeaders respBody respHeaders reqBodyJson
  = let resp = if isClientError status
          then mkClientErr respBody
          else mkResp status respBody respHeaders
    in
      Invocation
      eventId
      status
      (mkWebhookReq reqBodyJson reqHeaders invocationVersionST)
      resp

-- metadata database transactions

-- | Get cron trigger stats for cron jobs with fewer than 100 future reified
-- events in the database
--
-- The point here is to maintain a certain number of future events so the user
-- can kind of see what's coming up, and obviously to give 'processCronEvents'
-- something to do.
getDeprivedCronTriggerStatsTx :: [TriggerName] -> Q.TxE QErr [CronTriggerStats]
getDeprivedCronTriggerStatsTx cronTriggerNames =
  map (\(n, count, maxTx) -> CronTriggerStats n count maxTx) <$>
    Q.listQE defaultTxErrorHandler
    [Q.sql|
      SELECT t.trigger_name, coalesce(q.upcoming_events_count, 0), coalesce(q.max_scheduled_time, now())
      FROM (SELECT UNNEST ($1::text[]) as trigger_name) as t
      LEFT JOIN
      ( SELECT
         trigger_name,
          count(1) as upcoming_events_count,
          max(scheduled_time) as max_scheduled_time
         FROM hdb_catalog.hdb_cron_events
         WHERE tries = 0 and status = 'scheduled'
         GROUP BY trigger_name
      ) AS q
      ON t.trigger_name = q.trigger_name
      WHERE coalesce(q.upcoming_events_count, 0) < 100
     |] (Identity $ PGTextArray $ map triggerNameToTxt cronTriggerNames) True

-- TODO
--  - cron events have minute resolution, while one-off events have arbitrary
--    resolution, so it doesn't make sense to fetch them at the same rate
--  - if we decide to fetch cron events less frequently we should wake up that
--    thread at second 0 of every minute, and then pass hasura's now time into
--    the query (since the DB may disagree about the time)
getScheduledEventsForDeliveryTx :: Q.TxE QErr ([CronEvent], [OneOffScheduledEvent])
getScheduledEventsForDeliveryTx =
  (,) <$> getCronEventsForDelivery <*> getOneOffEventsForDelivery
  where
    getCronEventsForDelivery :: Q.TxE QErr [CronEvent]
    getCronEventsForDelivery =
      map (Q.getAltJ . runIdentity) <$> Q.listQE defaultTxErrorHandler [Q.sql|
        WITH cte AS
          ( UPDATE hdb_catalog.hdb_cron_events
            SET status = 'locked'
            WHERE id IN ( SELECT t.id
                          FROM hdb_catalog.hdb_cron_events t
                          WHERE ( t.status = 'scheduled'
                                  and (
                                   (t.next_retry_at is NULL and t.scheduled_time <= now()) or
                                   (t.next_retry_at is not NULL and t.next_retry_at <= now())
                                  )
                                )
                          FOR UPDATE SKIP LOCKED
                          )
            RETURNING *
          )
        SELECT row_to_json(t.*) FROM cte AS t
      |] () True

    getOneOffEventsForDelivery :: Q.TxE QErr [OneOffScheduledEvent]
    getOneOffEventsForDelivery = do
      map (Q.getAltJ . runIdentity) <$> Q.listQE defaultTxErrorHandler [Q.sql|
         WITH cte AS (
            UPDATE hdb_catalog.hdb_scheduled_events
            SET status = 'locked'
            WHERE id IN ( SELECT t.id
                          FROM hdb_catalog.hdb_scheduled_events t
                          WHERE ( t.status = 'scheduled'
                                  and (
                                   (t.next_retry_at is NULL and t.scheduled_time <= now()) or
                                   (t.next_retry_at is not NULL and t.next_retry_at <= now())
                                  )
                                )
                          FOR UPDATE SKIP LOCKED
                          )
            RETURNING *
          )
         SELECT row_to_json(t.*) FROM cte AS t
      |] () False

insertInvocationTx :: Invocation 'ScheduledType -> ScheduledEventType -> Q.TxE QErr ()
insertInvocationTx invo type' = do
  case type' of
    Cron -> do
      Q.unitQE defaultTxErrorHandler
        [Q.sql|
         INSERT INTO hdb_catalog.hdb_cron_event_invocation_logs
         (event_id, status, request, response)
         VALUES ($1, $2, $3, $4)
        |] ( iEventId invo
             , fromIntegral $ iStatus invo :: Int64
             , Q.AltJ $ J.toJSON $ iRequest invo
             , Q.AltJ $ J.toJSON $ iResponse invo) True
      Q.unitQE defaultTxErrorHandler [Q.sql|
          UPDATE hdb_catalog.hdb_cron_events
          SET tries = tries + 1
          WHERE id = $1
          |] (Identity $ iEventId invo) True
    OneOff -> do
      Q.unitQE defaultTxErrorHandler
        [Q.sql|
         INSERT INTO hdb_catalog.hdb_scheduled_event_invocation_logs
         (event_id, status, request, response)
         VALUES ($1, $2, $3, $4)
        |] ( iEventId invo
             , fromIntegral $ iStatus invo :: Int64
             , Q.AltJ $ J.toJSON $ iRequest invo
             , Q.AltJ $ J.toJSON $ iResponse invo) True
      Q.unitQE defaultTxErrorHandler [Q.sql|
          UPDATE hdb_catalog.hdb_scheduled_events
          SET tries = tries + 1
          WHERE id = $1
          |] (Identity $ iEventId invo) True

setScheduledEventOpTx
  :: ScheduledEventId -> ScheduledEventOp -> ScheduledEventType -> Q.TxE QErr ()
setScheduledEventOpTx eventId op type' = case op of
  SEOpRetry time    -> setRetry time
  SEOpStatus status -> setStatus status
  where
    setRetry time =
      case type' of
        Cron ->
          Q.unitQE defaultTxErrorHandler [Q.sql|
            UPDATE hdb_catalog.hdb_cron_events
            SET next_retry_at = $1,
            STATUS = 'scheduled'
            WHERE id = $2
            |] (time, eventId) True
        OneOff ->
          Q.unitQE defaultTxErrorHandler [Q.sql|
            UPDATE hdb_catalog.hdb_scheduled_events
            SET next_retry_at = $1,
            STATUS = 'scheduled'
            WHERE id = $2
            |] (time, eventId) True
    setStatus status =
      case type' of
        Cron -> do
          Q.unitQE defaultTxErrorHandler
           [Q.sql|
            UPDATE hdb_catalog.hdb_cron_events
            SET status = $2
            WHERE id = $1
           |] (eventId, status) True
        OneOff -> do
          Q.unitQE defaultTxErrorHandler
           [Q.sql|
            UPDATE hdb_catalog.hdb_scheduled_events
            SET status = $2
            WHERE id = $1
           |] (eventId, status) True

unlockScheduledEventsTx :: ScheduledEventType -> [ScheduledEventId] -> Q.TxE QErr Int
unlockScheduledEventsTx type' eventIds =
  let eventIdsTextArray = map unEventId eventIds
  in
  case type' of
    Cron ->
      (runIdentity . Q.getRow) <$> Q.withQE defaultTxErrorHandler
      [Q.sql|
        WITH "cte" AS
        (UPDATE hdb_catalog.hdb_cron_events
        SET status = 'scheduled'
        WHERE id = ANY($1::text[]) and status = 'locked'
        RETURNING *)
        SELECT count(*) FROM "cte"
      |] (Identity $ PGTextArray eventIdsTextArray) True
    OneOff ->
      (runIdentity . Q.getRow) <$> Q.withQE defaultTxErrorHandler
      [Q.sql|
        WITH "cte" AS
        (UPDATE hdb_catalog.hdb_scheduled_events
        SET status = 'scheduled'
        WHERE id = ANY($1::text[]) AND status = 'locked'
        RETURNING *)
        SELECT count(*) FROM "cte"
      |] (Identity $ PGTextArray eventIdsTextArray) True

unlockAllLockedScheduledEventsTx :: Q.TxE QErr ()
unlockAllLockedScheduledEventsTx = do
  Q.unitQE defaultTxErrorHandler [Q.sql|
          UPDATE hdb_catalog.hdb_cron_events
          SET status = 'scheduled'
          WHERE status = 'locked'
          |] () True
  Q.unitQE defaultTxErrorHandler [Q.sql|
          UPDATE hdb_catalog.hdb_scheduled_events
          SET status = 'scheduled'
          WHERE status = 'locked'
          |] () True

insertCronEventsTx :: [CronEventSeed] -> Q.TxE QErr ()
insertCronEventsTx cronSeeds = do
  let insertCronEventsSql = TB.run $ toSQL
        S.SQLInsert
          { siTable    = cronEventsTable
          , siCols     = map unsafePGCol ["trigger_name", "scheduled_time"]
          , siValues   = S.ValuesExp $ map (toTupleExp . toArr) cronSeeds
          , siConflict = Just $ S.DoNothing Nothing
          , siRet      = Nothing
          }
  Q.unitQE defaultTxErrorHandler (Q.fromText insertCronEventsSql) () False
  where
    toArr (CronEventSeed n t) = [(triggerNameToTxt n), (formatTime' t)]
    toTupleExp = S.TupleExp . map S.SELit

insertOneOffScheduledEventTx :: OneOffEvent -> Q.TxE QErr EventId
insertOneOffScheduledEventTx CreateScheduledEvent{..} =
  runIdentity . Q.getRow <$> Q.withQE defaultTxErrorHandler
    [Q.sql|
    INSERT INTO hdb_catalog.hdb_scheduled_events
    (webhook_conf,scheduled_time,payload,retry_conf,header_conf,comment)
    VALUES
    ($1, $2, $3, $4, $5, $6) RETURNING id
    |] ( Q.AltJ cseWebhook
      , cseScheduleAt
      , Q.AltJ csePayload
      , Q.AltJ cseRetryConf
      , Q.AltJ cseHeaders
      , cseComment)
      False

dropFutureCronEventsTx :: ClearCronEvents -> Q.TxE QErr ()
dropFutureCronEventsTx = \case
  SingleCronTrigger triggerName ->
    Q.unitQE defaultTxErrorHandler
    [Q.sql|
     DELETE FROM hdb_catalog.hdb_cron_events
     WHERE trigger_name = $1 AND scheduled_time > now() AND tries = 0
    |] (Identity triggerName) True
  MetadataCronTriggers triggerNames ->
    Q.unitQE defaultTxErrorHandler
    [Q.sql|
     DELETE FROM hdb_catalog.hdb_cron_events
     WHERE scheduled_time > now() AND tries = 0 AND trigger_name = ANY($1::text[])
    |] (Identity $ PGTextArray $ map triggerNameToTxt triggerNames) False

cronEventsTable :: QualifiedTable
cronEventsTable =
  QualifiedObject "hdb_catalog" $ TableName "hdb_cron_events"

mkScheduledEventStatusFilter :: [ScheduledEventStatus] -> S.BoolExp
mkScheduledEventStatusFilter = \case
  [] -> S.BELit True
  v  -> S.BEIN (S.SEIdentifier $ Identifier "status")
        $ map (S.SELit . scheduledEventStatusToText) v

scheduledTimeOrderBy :: S.OrderByExp
scheduledTimeOrderBy =
  let scheduledTimeCol = S.SEIdentifier $ Identifier "scheduled_time"
  in S.OrderByExp $ flip (NE.:|) [] $ S.OrderByItem scheduledTimeCol
     (Just S.OTAsc) Nothing

-- | Build a select expression which outputs total count and
-- list of json rows with pagination limit and offset applied
mkPaginationSelectExp
  :: S.Select
  -> ScheduledEventPagination
  -> S.Select
mkPaginationSelectExp allRowsSelect ScheduledEventPagination{..} =
  S.mkSelect
  { S.selCTEs = [(S.toAlias countCteAlias, allRowsSelect), (S.toAlias limitCteAlias, limitCteSelect)]
  , S.selExtr = [countExtractor, rowsExtractor]
  }
  where
    countCteAlias = Identifier "count_cte"
    limitCteAlias = Identifier "limit_cte"

    countExtractor =
      let selectExp = S.mkSelect
            { S.selExtr = [S.Extractor S.countStar Nothing]
            , S.selFrom = Just $ S.mkIdenFromExp countCteAlias
            }
      in S.Extractor (S.SESelect selectExp) Nothing

    limitCteSelect = S.mkSelect
      { S.selExtr = [S.selectStar]
      , S.selFrom = Just $ S.mkIdenFromExp countCteAlias
      , S.selLimit = (S.LimitExp . S.intToSQLExp) <$> _sepLimit
      , S.selOffset = (S.OffsetExp . S.intToSQLExp) <$> _sepOffset
      }

    rowsExtractor =
      let jsonAgg = S.SEUnsafe "json_agg(row_to_json(limit_cte.*))"
          selectExp = S.mkSelect
            { S.selExtr = [S.Extractor jsonAgg Nothing]
            , S.selFrom = Just $ S.mkIdenFromExp limitCteAlias
            }
      in S.Extractor (S.handleIfNull (S.SELit "[]") (S.SESelect selectExp)) Nothing

withCount :: (Int, Q.AltJ a) -> WithTotalCount a
withCount (count, Q.AltJ a) = WithTotalCount count a

getOneOffScheduledEventsTx
  :: ScheduledEventPagination
  -> [ScheduledEventStatus]
  -> Q.TxE QErr (WithTotalCount [OneOffScheduledEvent])
getOneOffScheduledEventsTx pagination statuses = do
  let table = QualifiedObject "hdb_catalog" $ TableName "hdb_scheduled_events"
      statusFilter = mkScheduledEventStatusFilter statuses
      select = S.mkSelect
               { S.selExtr = [S.selectStar]
               , S.selFrom = Just $ S.mkSimpleFromExp table
               , S.selWhere = Just $ S.WhereFrag statusFilter
               , S.selOrderBy = Just scheduledTimeOrderBy
               }
      sql = Q.fromBuilder $ toSQL $ mkPaginationSelectExp select pagination
  (withCount . Q.getRow) <$> Q.withQE defaultTxErrorHandler sql () False

getCronEventsTx
  :: TriggerName
  -> ScheduledEventPagination
  -> [ScheduledEventStatus]
  -> Q.TxE QErr (WithTotalCount [CronEvent])
getCronEventsTx triggerName pagination status = do
  let triggerNameFilter =
        S.BECompare S.SEQ (S.SEIdentifier $ Identifier "trigger_name") (S.SELit $ triggerNameToTxt triggerName)
      statusFilter = mkScheduledEventStatusFilter status
      select = S.mkSelect
               { S.selExtr = [S.selectStar]
               , S.selFrom = Just $ S.mkSimpleFromExp cronEventsTable
               , S.selWhere = Just $ S.WhereFrag $ S.BEBin S.AndOp triggerNameFilter statusFilter
               , S.selOrderBy = Just scheduledTimeOrderBy
               }
      sql = Q.fromBuilder $ toSQL $ mkPaginationSelectExp select pagination
  (withCount . Q.getRow) <$> Q.withQE defaultTxErrorHandler sql () False

deleteScheduledEventTx
  :: ScheduledEventId -> ScheduledEventType -> Q.TxE QErr ()
deleteScheduledEventTx eventId = \case
  OneOff ->
    Q.unitQE defaultTxErrorHandler [Q.sql|
      DELETE FROM hdb_catalog.hdb_scheduled_events
       WHERE id = $1
    |] (Identity eventId) False
  Cron  ->
    Q.unitQE defaultTxErrorHandler [Q.sql|
      DELETE FROM hdb_catalog.hdb_cron_events
       WHERE id = $1
    |] (Identity eventId) False

invocationFieldExtractors :: QualifiedTable -> [S.Extractor]
invocationFieldExtractors table =
  [ S.Extractor (seIden "id") Nothing
  , S.Extractor (seIden "event_id") Nothing
  , S.Extractor (seIden "status") Nothing
  , S.Extractor (withJsonTypeAnn $ seIden "request") Nothing
  , S.Extractor (withJsonTypeAnn $ seIden "response") Nothing
  , S.Extractor (seIden "created_at") Nothing
  ]
  where
    withJsonTypeAnn e = S.SETyAnn e $ S.TypeAnn "json"
    seIden = S.SEQIdentifier . S.mkQIdentifierTable table . Identifier

mkEventIdBoolExp :: QualifiedTable -> EventId -> S.BoolExp
mkEventIdBoolExp table eventId =
  S.BECompare S.SEQ (S.SEQIdentifier $ S.mkQIdentifierTable table $ Identifier "event_id")
  (S.SELit $ unEventId eventId)

getInvocationsTx
  :: GetInvocationsBy
  -> ScheduledEventPagination
  -> Q.TxE QErr (WithTotalCount [ScheduledEventInvocation])
getInvocationsTx invocationsBy pagination = do
  let eventsTables = EventTables oneOffInvocationsTable cronInvocationsTable cronEventsTable
      sql = Q.fromBuilder $ toSQL $ getInvocationsQuery eventsTables invocationsBy pagination
  (withCount . Q.getRow) <$> Q.withQE defaultTxErrorHandler sql () True
  where
    oneOffInvocationsTable = QualifiedObject "hdb_catalog" $ TableName "hdb_scheduled_event_invocation_logs"
    cronInvocationsTable = QualifiedObject "hdb_catalog" $ TableName "hdb_cron_event_invocation_logs"

data EventTables
  = EventTables
  { etOneOffInvocationsTable :: QualifiedTable
  , etCronInvocationsTable   :: QualifiedTable
  , etCronEventsTable        :: QualifiedTable
  }

getInvocationsQueryNoPagination :: EventTables -> GetInvocationsBy -> S.Select
getInvocationsQueryNoPagination (EventTables oneOffInvocationsTable cronInvocationsTable cronEventsTable') invocationsBy =
    allRowsSelect
  where
    createdAtOrderBy table =
      let createdAtCol = S.SEQIdentifier $ S.mkQIdentifierTable table $ Identifier "created_at"
      in S.OrderByExp $ flip (NE.:|) [] $ S.OrderByItem createdAtCol (Just S.OTDesc) Nothing

    allRowsSelect = case invocationsBy of
      GIBEventId eventId eventType ->
        let table = case eventType of
              OneOff -> oneOffInvocationsTable
              Cron   -> cronInvocationsTable
        in S.mkSelect
           { S.selExtr = invocationFieldExtractors table
           , S.selFrom = Just $ S.mkSimpleFromExp table
           , S.selOrderBy = Just $ createdAtOrderBy table
           , S.selWhere = Just $ S.WhereFrag $ mkEventIdBoolExp table eventId
           }

      GIBEvent event -> case event of
        SEOneOff ->
          let table = oneOffInvocationsTable
          in S.mkSelect
             { S.selExtr = invocationFieldExtractors table
             , S.selFrom = Just $ S.mkSimpleFromExp table
             , S.selOrderBy = Just $ createdAtOrderBy table
             }
        SECron triggerName ->
          let invocationTable = cronInvocationsTable
              eventTable = cronEventsTable'
              joinCondition = S.JoinOn $ S.BECompare S.SEQ
                (S.SEQIdentifier $ S.mkQIdentifierTable eventTable $ Identifier "id")
                (S.SEQIdentifier $ S.mkQIdentifierTable invocationTable $ Identifier "event_id")
              joinTables =
                S.JoinExpr (S.FISimple invocationTable Nothing) S.Inner
                     (S.FISimple eventTable Nothing) joinCondition
              triggerBoolExp = S.BECompare S.SEQ
                (S.SEQIdentifier $ S.mkQIdentifierTable eventTable (Identifier "trigger_name"))
                (S.SELit $ triggerNameToTxt triggerName)

          in S.mkSelect
             { S.selExtr = invocationFieldExtractors invocationTable
             , S.selFrom = Just $ S.FromExp [S.FIJoin joinTables]
             , S.selWhere = Just $ S.WhereFrag triggerBoolExp
             , S.selOrderBy = Just $ createdAtOrderBy invocationTable
             }

getInvocationsQuery :: EventTables -> GetInvocationsBy -> ScheduledEventPagination -> S.Select
getInvocationsQuery ets invocationsBy pagination =
  mkPaginationSelectExp (getInvocationsQueryNoPagination ets invocationsBy) pagination
