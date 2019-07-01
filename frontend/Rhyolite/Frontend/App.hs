{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Rhyolite.Frontend.App where

import Control.DeepSeq
import Control.Monad.Exception
import Control.Monad.Identity
import Control.Monad.Primitive
import Control.Monad.Reader
import Control.Monad.Ref
import Control.Monad.State.Strict
import Data.Aeson
import Data.Aeson.Types
import Data.Bifunctor
import qualified Data.ByteString.Lazy as LBS
import Data.Coerce (coerce)
import Data.Constraint (Dict (..))
import Data.Default (Default)
import qualified Data.IntMap as IntMap
import Data.Dependent.Map (DSum (..))
import qualified Data.Map as Map
import Data.Semigroup ((<>))
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)
import Debug.Trace (trace)
import GHC.Generics (Generic)
import Obelisk.Route.Frontend (Routed(..), SetRoute(..), RouteToUrl(..))
import Network.URI (URI)
import qualified Reflex as R
import Reflex.Dom.Core hiding (MonadWidget, Request, fmapMaybe)
import Reflex.Host.Class
import Reflex.Time (throttleBatchWithLag)
import Reflex.FunctorMaybe
{- import System.CPUTime (getCPUTime) -}
import Data.Time.Clock (getCurrentTime, diffUTCTime, UTCTime)
import System.IO.Unsafe (unsafePerformIO)

import Rhyolite.Api
import Rhyolite.App
import Rhyolite.Request.Class
import Rhyolite.WebSocket

#if defined(ghcjs_HOST_OS)
import GHCJS.DOM.Types (MonadJSM, pFromJSVal)
#else
import GHCJS.DOM.Types (MonadJSM(..))
import Rhyolite.Request.Common (decodeValue')
#endif

type RhyoliteWidgetInternal app t m = QueryT t (ViewSelector app SelectedCount) (RequesterT t (AppRequest app) Identity m)

newtype RhyoliteWidget app t m a = RhyoliteWidget { unRhyoliteWidget :: RhyoliteWidgetInternal app t m a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadFix, MonadException)

deriving instance (q ~ (ViewSelector app SelectedCount)
                  , Group (ViewSelector app SelectedCount)
                  , Additive (ViewSelector app SelectedCount)
                  , Query (ViewSelector app SelectedCount)
                  , Reflex t
                  , Monad m)
                  => MonadQuery t q (RhyoliteWidget app t m)

#if !defined(ghcjs_HOST_OS)
instance MonadJSM m => MonadJSM (RhyoliteWidget app t m) where
  liftJSM' = lift . liftJSM'
#endif

instance MonadTrans (RhyoliteWidget app t) where
  lift = RhyoliteWidget . lift . lift

instance HasJS x m => HasJS x (RhyoliteWidget app t m) where
  type JSX (RhyoliteWidget app t m) = JSX m
  liftJS = lift . liftJS

instance HasDocument m => HasDocument (RhyoliteWidget app t m) where
  askDocument = RhyoliteWidget . lift . lift $ askDocument

instance (MonadWidget' t m, PrimMonad m) => Requester t (RhyoliteWidget app t m) where
  type Request (RhyoliteWidget app t m) = AppRequest app
  type Response (RhyoliteWidget app t m) = Identity
  requesting = RhyoliteWidget . requesting
  requesting_ = RhyoliteWidget . requesting_

instance PerformEvent t m => PerformEvent t (RhyoliteWidget app t m) where
  type Performable (RhyoliteWidget app t m) = Performable m
  performEvent_ = lift . performEvent_
  performEvent = lift . performEvent

instance TriggerEvent t m => TriggerEvent t (RhyoliteWidget app t m) where
  newTriggerEvent = lift newTriggerEvent
  newTriggerEventWithOnComplete = lift newTriggerEventWithOnComplete
  newEventWithLazyTriggerWithOnComplete = lift . newEventWithLazyTriggerWithOnComplete

instance NotReady t m => NotReady t (RhyoliteWidget app t m)

instance (HasView app, DomBuilder t m, MonadHold t m, Ref (Performable m) ~ Ref m, MonadFix m, Group (ViewSelector app SelectedCount), Additive (ViewSelector app SelectedCount)) => DomBuilder t (RhyoliteWidget app t m) where
  type DomBuilderSpace (RhyoliteWidget app t m) = DomBuilderSpace m
  textNode = liftTextNode
  element elementTag cfg (RhyoliteWidget child) = RhyoliteWidget $ element elementTag cfg child
  inputElement = RhyoliteWidget . inputElement
  textAreaElement = RhyoliteWidget . textAreaElement
  selectElement cfg (RhyoliteWidget child) = RhyoliteWidget $ selectElement cfg child
  placeRawElement = RhyoliteWidget . placeRawElement
  wrapRawElement e = RhyoliteWidget . wrapRawElement e

instance (Reflex t, MonadFix m, MonadHold t m, Adjustable t m, Group (ViewSelector app SelectedCount), Additive (ViewSelector app SelectedCount), Query (ViewSelector app SelectedCount), Eq (ViewSelector app SelectedCount)) => Adjustable t (RhyoliteWidget app t m) where
  runWithReplace a0 a' = RhyoliteWidget $ runWithReplace (coerce a0) (coerceEvent a')
  traverseDMapWithKeyWithAdjust f dm0 dm' = RhyoliteWidget $ traverseDMapWithKeyWithAdjust (\k v -> unRhyoliteWidget $ f k v) (coerce dm0) (coerceEvent dm')
  traverseDMapWithKeyWithAdjustWithMove f dm0 dm' = RhyoliteWidget $ traverseDMapWithKeyWithAdjustWithMove (\k v -> unRhyoliteWidget $ f k v) (coerce dm0) (coerceEvent dm')
  traverseIntMapWithKeyWithAdjust f dm0 dm' = RhyoliteWidget $ traverseIntMapWithKeyWithAdjust (\k v -> unRhyoliteWidget $ f k v) (coerce dm0) (coerceEvent dm')

instance PostBuild t m => PostBuild t (RhyoliteWidget app t m) where
  getPostBuild = lift getPostBuild

instance MonadRef m => MonadRef (RhyoliteWidget app t m) where
  type Ref (RhyoliteWidget app t m) = Ref m
  newRef = RhyoliteWidget . newRef
  readRef = RhyoliteWidget . readRef
  writeRef r = RhyoliteWidget . writeRef r

instance MonadHold t m => MonadHold t (RhyoliteWidget app t m) where
  hold a = RhyoliteWidget . hold a
  holdDyn a = RhyoliteWidget . holdDyn a
  holdIncremental a = RhyoliteWidget . holdIncremental a
  buildDynamic a = RhyoliteWidget . buildDynamic a
  headE = RhyoliteWidget . headE

instance MonadSample t m => MonadSample t (RhyoliteWidget app t m) where
  sample = RhyoliteWidget . sample

instance HasJSContext m => HasJSContext (RhyoliteWidget app t m) where
  type JSContextPhantom (RhyoliteWidget app t m) = JSContextPhantom m
  askJSContext = RhyoliteWidget askJSContext

instance MonadReflexCreateTrigger t m => MonadReflexCreateTrigger t (RhyoliteWidget app t m) where
  newEventWithTrigger = RhyoliteWidget . newEventWithTrigger
  newFanEventWithTrigger a = RhyoliteWidget . lift $ newFanEventWithTrigger a

instance (Monad m, Routed t r m) => Routed t r (RhyoliteWidget app t m) where
  askRoute = lift askRoute

instance (Monad m, SetRoute t r m) => SetRoute t r (RhyoliteWidget app t m) where
  modifyRoute = lift . modifyRoute

instance (Monad m, RouteToUrl r m) => RouteToUrl r (RhyoliteWidget app t m) where
  askRouteToUrl = lift askRouteToUrl

deriving instance ( Reflex t
                  , Prerender js t m
                  , MonadFix m
                  , Group (ViewSelector app SelectedCount)
                  , Additive (ViewSelector app SelectedCount)
                  , Query (ViewSelector app SelectedCount)
                  , Eq (ViewSelector app SelectedCount)
                  ) => Prerender js t (RhyoliteWidget app t m)

instance PrimMonad m => PrimMonad (RhyoliteWidget app t m) where
  type PrimState (RhyoliteWidget app t m) = PrimState m
  primitive = lift . primitive

deriving instance DomRenderHook t m => DomRenderHook t (RhyoliteWidget app t m)

-- | This synonym adds constraints to MonadRhyoliteWidget that are only available on the frontend, and not via backend rendering.
type MonadRhyoliteFrontendWidget app t m =
    ( MonadRhyoliteWidget app t m
    , DomBuilderSpace m ~ GhcjsDomSpace
    )

class ( MonadWidget' t m
      , Requester t m
      , R.Request m ~ AppRequest app
      , Response m ~ Identity
      , HasRequest app
      , HasView app
      , Group (ViewSelector app SelectedCount)
      , Additive (ViewSelector app SelectedCount)
      , MonadQuery t (ViewSelector app SelectedCount) m
      ) => MonadRhyoliteWidget app t m | m -> app t where

instance ( MonadWidget' t m
         , Requester t m
         , R.Request m ~ AppRequest app
         , Response m ~ Identity
         , HasRequest app
         , HasView app
         , Group (ViewSelector app SelectedCount)
         , Additive (ViewSelector app SelectedCount)
         , MonadQuery t (ViewSelector app SelectedCount) m
         ) => MonadRhyoliteWidget app t m

queryDynUniq :: ( Monad m
                , Reflex t
                , MonadQuery t q m
                , MonadHold t m
                , MonadFix m
                , Eq (QueryResult q)
                )
             => Dynamic t q
             -> m (Dynamic t (QueryResult q))
queryDynUniq = holdUniqDyn <=< queryDyn

watchViewSelector :: ( Monad m
                     , Reflex t
                     , MonadQuery t q m
                     , MonadHold t m
                     , MonadFix m
                     , Eq (QueryResult q)
                     )
                  => Dynamic t q
                  -> m (Dynamic t (QueryResult q))
watchViewSelector = queryDynUniq

--TODO: HasDocument is still not accounted for
type MonadWidget' t m =
  ( DomBuilder t m
  , MonadFix m
  , MonadHold t m
  , MonadSample t (Performable m)
  , MonadReflexCreateTrigger t m
  , PostBuild t m
  , PerformEvent t m
  , TriggerEvent t m
  -- , MonadIO m
  , MonadIO (Performable m)
  -- , MonadJSM m
  -- , MonadJSM (Performable m)
  -- , HasJSContext m
  -- , HasJSContext (Performable m)
  -- , MonadAsyncException m
  -- , MonadAsyncException (Performable m)
  , MonadRef m
  , Ref m ~ Ref IO
  , MonadRef (Performable m)
  , Ref (Performable m) ~ Ref IO
  )

runPrerenderedRhyoliteWidget
   :: forall app m t b x.
      ( QueryResult (ViewSelector app SelectedCount) ~ View app SelectedCount
      , HasView app
      , HasRequest app
      , Eq (ViewSelector app SelectedCount)
      , PerformEvent t m
      , TriggerEvent t m
      , PostBuild t m, MonadHold t m
      , MonadFix m
      , Prerender x t m
      , MonadIO (Performable m)
      )
   => Text
   -> RhyoliteWidget app t m b
   -> m b
runPrerenderedRhyoliteWidget url child = do
  rec (notification :: Event t (View app ()), response) <- fmap (bimap (switch . current) (switch . current) . splitDynPure) $
        prerender (return (never, never)) $ do
          appWebSocket :: AppWebSocket t app <- openWebSocket' url request'' $ fmapMaybe (\c -> if c == mempty then Nothing else Just ()) <$> nubbedVs
          return ( _appWebSocket_notification appWebSocket
                 , _appWebSocket_response appWebSocket
                 )
      (request', response') <- identifyTags request $ ffor response $ \(TaggedResponse t v) -> (t, v)
      let request'' = fmap (fmapMaybe (\(t, v) -> case fromJSON v of
            Success (v' :: (SomeRequest (AppRequest app))) -> Just $ TaggedRequest t v'
            _ -> Nothing)) request'
      ((a, vs), request) <- flip runRequesterT response' $ runQueryT (unRhyoliteWidget child) view
      nubbedVs :: Dynamic t (ViewSelector app SelectedCount) <- holdUniqDyn $ incrementalToDynamic (vs :: Incremental t (AdditivePatch (ViewSelector app SelectedCount)))
      view <- fromNotifications nubbedVs $ fmap (\_ -> SelectedCount 1) <$> notification
  return a

runRhyoliteWidget
   :: forall app m t b x.
      ( QueryResult (ViewSelector app SelectedCount) ~ View app SelectedCount
      , HasView app
      , HasRequest app
      , Eq (ViewSelector app SelectedCount)
      , HasJS x m, HasJSContext m, PerformEvent t m
      , TriggerEvent t m
      , PostBuild t m, MonadHold t m, MonadJSM (Performable m), MonadJSM m
      , MonadFix m
      , MonadIO (Performable m)
      )
   => Text
   -> RhyoliteWidget app t m b
   -> m (AppWebSocket t app, b)
runRhyoliteWidget url child = do
  rec appWebSocket <- openWebSocket' url request'' $ fmapMaybe (\c -> if c == mempty then Nothing else Just ()) <$> nubbedVs
      let notification = _appWebSocket_notification appWebSocket
          response = _appWebSocket_response appWebSocket
      (request', response') <- identifyTags request $ ffor response $ \(TaggedResponse t v) -> (t, v)
      let request'' = fmap (fmapMaybe (\(t, v) -> case fromJSON v of
            Success (v' :: (SomeRequest (AppRequest app))) -> Just $ TaggedRequest t v'
            _ -> Nothing)) request'
      ((a, vs), request) <- flip runRequesterT response' $ runQueryT (unRhyoliteWidget child) view
      nubbedVs :: Dynamic t (ViewSelector app SelectedCount) <- holdUniqDyn $ incrementalToDynamic (vs :: Incremental t (AdditivePatch (ViewSelector app SelectedCount)))
      view <- fromNotifications nubbedVs $ fmap (\_ -> SelectedCount 1) <$> notification
  return (appWebSocket, a)

fromNotifications :: forall m (t :: *) vs. (Query vs, MonadHold t m, PerformEvent t m, TriggerEvent t m, MonadIO (Performable m), Reflex t, MonadFix m, Monoid (QueryResult vs))
                  => Dynamic t vs
                  -> Event t (QueryResult vs)
                  -> m (Dynamic t (QueryResult vs))
fromNotifications vs ePatch = do
  ePatchThrottled <- throttleBatchWithLag lag ePatch
  foldDyn (\(vs', p) v -> cropView vs' $ p <> v) mempty $ attach (current vs) ePatchThrottled
  where
    lag e = performEventAsync $ ffor e $ \a cb -> liftIO $ cb a

data Decoder f = forall a. FromJSON a => Decoder (f a)

identifyTags
  :: forall t v m.
     ( MonadFix m
     , MonadHold t m
     , Reflex t
     , Request v
     )
  => Event t (RequesterData v)
  -> Event t (Data.Aeson.Value, Data.Aeson.Value)
  -> m ( Event t [(Data.Aeson.Value, Data.Aeson.Value)]
       , Event t (RequesterData Identity)
       )
identifyTags send recv = do
  rec nextId :: Behavior t Int <- hold 1 $ fmap (\(a, _, _) -> a) send'
      waitingFor :: Incremental t (PatchMap Int (Decoder RequesterDataKey)) <- holdIncremental mempty $ leftmost
        [ fmap (\(_, b, _) -> b) send'
        , fmap snd recv'
        ]
      let send' = flip pushAlways send $ \dm -> do
            oldNextId <- sample nextId
            let (result, newNextId) = flip runState oldNextId $ forM (requesterDataToList dm) $ \(k :=> v) -> do
                  n <- get
                  put $ succ n
                  return (n, k :=> v)
                patchWaitingFor = PatchMap $ Map.fromList $ ffor result $ \(n, k :=> v) -> case requestResponseFromJSON v of
                  Dict -> (n, Just (Decoder k))
                toSend = ffor result $ \(n, _ :=> v) -> (toJSON n, requestToJSON v)
            return (newNextId, patchWaitingFor, toSend)
      let recv' = flip push recv $ \(jsonN, jsonV) -> do
            wf <- sample $ currentIncremental waitingFor
            case parseMaybe parseJSON jsonN of
              Nothing -> return Nothing
              Just n ->
                return $ case Map.lookup n wf of
                  Just (Decoder k) -> Just $
                    let Just v = parseMaybe parseJSON jsonV
                    in (singletonRequesterData k $ Identity v, PatchMap $ Map.singleton n Nothing)
                  Nothing -> Nothing
  return (fmap (\(_, _, c) -> c) send', fst <$> recv')

data AppWebSocket t app = AppWebSocket
  { _appWebSocket_notification :: Event t (View app ())
  , _appWebSocket_response :: Event t TaggedResponse
  , _appWebSocket_version :: Event t Text
  , _appWebSocket_connected :: Dynamic t Bool
  }

{-# NOINLINE unsafeGetTime #-}
unsafeGetTime :: a -> (UTCTime, a)
unsafeGetTime a = unsafePerformIO $ do
  let getGetCurrentTime _ = a `seq` getCurrentTime
  t <- getGetCurrentTime ()
  pure (t, a)

{- traceCallDuration :: String -> (b -> a) -> b -> a -}
{- traceCallDuration name f v = -}
{-   let -}
{-     (t0, v0) = unsafeGetTime v -}
{-     (t1, r) = unsafeGetTime $ f v -}
{-   in -}
{-     trace (name <> " took: " <> show  (t1 `diffUTCTime` t0) <> " seconds. ") r -}

{-# NOINLINE traceCallDuration #-}
traceCallDuration :: String -> (b -> a) -> b -> a
traceCallDuration name f v = unsafePerformIO $ do
  {- t0 <- v `seq` getCPUTime -}
  t0 <- v `seq` getCurrentTime
  let r = f v
  t1 <- r `seq` getCurrentTime
  putStrLn $ name <> " start time: " <> show t0
  putStrLn $ name <> " end time: " <> show t1
  putStrLn $ name <> " took: " <> show ((t1 `diffUTCTime` t0)) <> " seconds."
  pure r

{-# NOINLINE traceCallDurationDeep #-}
traceCallDurationDeep :: (NFData a, NFData b) => String -> (b -> a) -> b -> a
traceCallDurationDeep name f v = unsafePerformIO $ do
  {- t0 <- v `seq` getCPUTime -}
  t0 <- v `deepseq` getCurrentTime
  let r = f v
  t1 <- r `deepseq` getCurrentTime
  putStrLn $ name <> " start time: " <> show t0
  putStrLn $ name <> " end time: " <> show t1
  putStrLn $ name <> " took: " <> show ((t1 `diffUTCTime` t0)) <> " seconds."
  pure r

-- | Open a websocket connection and split resulting incoming traffic into listen notification and api response channels
openWebSocket' :: forall app t x m.
                 ( MonadJSM m
                 , MonadJSM (Performable m)
                 , PostBuild t m
                 , TriggerEvent t m
                 , PerformEvent t m
                 , HasJSContext m
                 , HasJS x m
                 , MonadFix m
                 , MonadHold t m
                 , HasView app
                 , HasRequest app
                 )
              => Text -- ^ A complete URL
              -> Event t [TaggedRequest (AppRequest app)] -- ^ Outbound requests
              -> Dynamic t (ViewSelector app ()) -- ^ Authenticated listen requests (e.g., ViewSelector updates)
              -> m (AppWebSocket t app)
openWebSocket' url request vs = do
#if defined(ghcjs_HOST_OS)
  rec let
          jsonDecodeTraced = traceCallDuration "jsonDecode" jsonDecode
          pFromJSValTraced = traceCallDuration "pFromJSVal" pFromJSVal
          platformDecode = traceCallDuration "platformDecode" (jsonDecodeTraced . pFromJSValTraced)
          rawWebSocket cfg = webSocket' url cfg (either (error "webSocket': expected JSVal") return)
      ws <- rawWebSocket $ def
#else
  rec let
        decodeValue'Traced = traceCallDuration "decodeValue'" decodeValue'
        fromStrictTraced = traceCallDuration "LBS.fromStrict" LBS.fromStrict
        platformDecode = traceCallDuration "platformDecode" (decodeValue'Traced . fromStrictTraced)
      ws <- webSocket url $ def
#endif
        & webSocketConfig_send .~ fmap (map (traceCallDuration "encode" (decodeUtf8 . LBS.toStrict . encode))) (mconcat
          [ fmap (map WebSocketRequest_Api) request
          , fmap ((:[]) . WebSocketRequest_ViewSelector) $ updated vs :: Event t [WebSocketRequest app (AppRequest app)]
          , tag (fmap ((:[]) . WebSocketRequest_ViewSelector) $ current vs) $ _webSocket_open ws
          ])
  let (eMessages :: Event t (WebSocketResponse app)) = fmapMaybe platformDecode $ _webSocket_recv ws
      notification = fforMaybe eMessages $ \case
        WebSocketResponse_View v -> Just v
        _ -> Nothing
      response = fforMaybe eMessages $ \case
        WebSocketResponse_Api r -> Just r
        _ -> Nothing
      version = fforMaybe eMessages $ \case
        WebSocketResponse_Version v -> Just v
        _ -> Nothing
  connected <- holdDyn False . leftmost $ [True <$ _webSocket_open ws, False <$ _webSocket_close ws]
  return $ AppWebSocket
    { _appWebSocket_notification = notification
    , _appWebSocket_response = response
    , _appWebSocket_version = version
    , _appWebSocket_connected = connected
    }

openWebSocket :: forall t x m app.
                 ( MonadJSM m
                 , MonadJSM (Performable m)
                 , PostBuild t m
                 , TriggerEvent t m
                 , PerformEvent t m
                 , HasJSContext m
                 , HasJS x m
                 , MonadFix m
                 , MonadHold t m
                 , HasRequest app
                 , HasView app
                 )
              => Text -- ^ A complete URL
              -> Event t [TaggedRequest (AppRequest app)] -- ^ Outbound requests
              -> Dynamic t (ViewSelector app ()) -- ^ current ViewSelector
              -> m ( Event t (View app ())
                   , Event t TaggedResponse
                   )
openWebSocket murl request vs = do
  aws <- openWebSocket' murl request vs
  return (_appWebSocket_notification aws, _appWebSocket_response aws)

data DeviceToken = DeviceToken_Android Text
                 | DeviceToken_iOS Text
  deriving (Show, Read, Eq, Ord, Generic)

instance FromJSON DeviceToken
instance ToJSON DeviceToken

data FrontendConfig = FrontendConfig
  { _frontendConfig_registerDeviceForNotifications :: Maybe (DeviceToken -> IO ())
  , _frontendConfig_uriCallback :: Maybe (URI -> IO ())
  , _frontendConfig_warpPort :: Int
  }

instance Default FrontendConfig where
  def = FrontendConfig
    { _frontendConfig_registerDeviceForNotifications = Nothing
    , _frontendConfig_uriCallback = Nothing
    , _frontendConfig_warpPort = 3911
    }

-- | Map application credentials into an "authenticated" subwidget
-- This relieves us of having to carry around application credentials in parts of the application
-- known to be accessible only to authenticated users.
-- For example, you might define a view selector @VS (Map k) a@ and in the authenticated parts of the application
-- the @k@ would be '()'. At top level, this the '()'s would be replaced by a 'QueryMorphism' with the actual credential to
-- be sent to the backend.
mapAuth
  :: forall app a f t m.
     ( MonadFix m
     , PostBuild t m
     , Query (ViewSelector app SelectedCount)
     , Group (ViewSelector app SelectedCount)
     , Additive (ViewSelector app SelectedCount)
     , Group (f SelectedCount)
     , Additive (f SelectedCount)
     )
  => AppCredential app
  -- ^ The application's authentication token, used to transform api calls made by the authenticated child widget
  -> QueryMorphism (f SelectedCount) (ViewSelector app SelectedCount)
    -- ^ A morphism from a query type supplied by the user, "f", that represents queries made by authenticated widgets, to a the query
    -- type of the application as a whole (which may have authenticated and public components)
  -> QueryT t (f SelectedCount) (RequesterT t (ApiRequest () (PublicRequest app) (PrivateRequest app)) Identity m) a
  -- ^ The authenticated child widget. It uses '()' as its credential for private requests
  -> RhyoliteWidget app t m a
mapAuth token authorizeQuery authenticatedChild = RhyoliteWidget $ do
  v <- askQueryResult
  (a, vs) <- lift $ mapRequesterT authorizeReq id $ runQueryT (withQueryT authorizeQuery authenticatedChild) v
  -- tellQueryIncremental vs would seem simpler, but tellQueryDyn is more baked, subtracting off the removals properly.
  tellQueryDyn $ incrementalToDynamic vs
  return a
  where
    authorizeReq
      :: forall x. ApiRequest () (PublicRequest app) (PrivateRequest app) x
      -> ApiRequest (AppCredential app) (PublicRequest app) (PrivateRequest app) x
    authorizeReq = \case
      ApiRequest_Public a -> ApiRequest_Public a
      ApiRequest_Private () a -> ApiRequest_Private token a

-- TODO: Upstream to reflex
mapRequesterT
  :: (Reflex t, MonadFix m)
  => (forall x. req x -> req' x)
  -> (forall x. rsp' x -> rsp x)
  -> RequesterT t req rsp m a
  -> RequesterT t req' rsp' m a
mapRequesterT freq frsp child = do
  rec let rsp = fmap (runIdentity . traverseRequesterData (Identity . frsp)) rsp'
      (a, req) <- lift $ runRequesterT child rsp
      rsp' <- fmap (flip selectInt 0 . fanInt . fmapCheap unMultiEntry) $ requesting' $
        fmapCheap (multiEntry . IntMap.singleton 0) $ fmap (runIdentity . traverseRequesterData (Identity . freq)) req
  return a
