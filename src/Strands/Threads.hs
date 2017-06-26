{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE ScopedTypeVariables       #-}

module Strands.Threads
    ( parallel
    , waitEvents
    , async
    , sample
    , sync
    --, react
    , threads

    , wait
    , gather
    )
where

import           Control.Applicative         ((<|>), empty)
import           Control.Concurrent          (ThreadId, forkIO, killThread,
                                              myThreadId, threadDelay)
import           Control.Concurrent.STM      (TChan, atomically, newTChan,
                                              readTChan, tryReadTChan,
                                              writeTChan)
import           Control.Exception           (ErrorCall (..),
                                              SomeException (..), catch)
import qualified Control.Exception.Lifted    as EL
import           Control.Monad.Catch         (MonadCatch, MonadThrow, throwM,
                                              try)
import           Control.Monad.IO.Class      (MonadIO (..))
import           Control.Monad.State         (get, gets, modify, mzero,
                                              runStateT, when, StateT)
import           Control.Monad.Trans.Class   (MonadTrans (lift))
import           Control.Monad.Trans.Control (MonadBaseControl, liftBaseWith)
import           Data.Dynamic                (Typeable)
import           Data.IORef                  (IORef, atomicModifyIORef,
                                              modifyIORef, newIORef, readIORef,
                                              writeIORef)
import           Data.List                   (delete)
import           Data.Maybe                  (fromJust, isJust)
import           Unsafe.Coerce               (unsafeCoerce)

import           Strands.AsyncT
import           Strands.Context

------------------------------------------------------------------------------
-- Model of computation
------------------------------------------------------------------------------

-- A computation starts in a top level thread. If no "forking primitives" are
-- used then the thread finishes in a straight line flow just like the IO
-- monad. However, if a "forking primitive" is used it "forks" the computation
-- into multiple flows.  The "forked" computations may run concurrently (and
-- therefore in parallel when possible) or serially. When multiple forking
-- primitives are composed it results into a tree of computations where each
-- branch of the tree can run concurrently.
--
-- A forking primitive may create multiple forks at that point, each fork
-- provides a specific input value to be used in the forked computation, this
-- value defines the fork.
--
-- The final result of the computation is the collection of all the values
-- generated by all the leaf level forks. These values are then propagated up
-- the tree and collected at the root of the tree.
--
-- Since AsyncT is a transformer we can use things like pipe, conduit or any
-- other transformer monads inside the computations to utilize single threaded
-- composition or data flow techniques.
--
------------------------------------------------------------------------------
-- Pick up from where we left in the previous thread
------------------------------------------------------------------------------

-- | Continue execution of the closure that we were executing when we migrated
-- to a new thread.

runContext :: MonadIO m => Context -> StateT Context m ()
runContext ctx = do
        let s = runAsyncT (composeContext ctx)
        _ <- lift $ runStateT s ctx
        return ()

------------------------------------------------------------------------------
-- Thread Management (creation, reaping and killing)
------------------------------------------------------------------------------

-- XXX We are using unbounded channels so this will not block on writing to
-- pchan. We can use bounded channels to throttle the creation of threads based
-- on consumption rate.
processOneEvent :: MonadIO m
    => ChildEvent a
    -> [ThreadId]
    -> m ([ThreadId], Maybe SomeException)
processOneEvent (ChildDone tid e) pending = do
    when (isJust e) $ liftIO $ mapM_ killThread pending
    return (delete tid pending, Nothing)

drainChildren :: MonadIO m
    => TChan (ChildEvent a)
    -> [ThreadId]
    -> m ([ThreadId], Maybe SomeException)
drainChildren cchan pending =
    case pending of
        [] -> return (pending, Nothing)
        _  ->  do
            ev <- liftIO $ atomically $ readTChan cchan
            (p, e) <- processOneEvent ev pending
            maybe (drainChildren cchan p) (const $ return (p, e)) e

waitForChildren :: MonadIO m => Context -> m (Maybe SomeException)
waitForChildren ctx = do
    let pendingRef = pendingThreads ctx
    pending <- liftIO $ readIORef pendingRef
    (p, e) <- drainChildren (childChannel ctx) pending
    liftIO $ writeIORef pendingRef p
    return e

tryReclaimZombies :: (MonadIO m, MonadThrow m) => Context -> m ()
tryReclaimZombies ctx = do
    let cchan = childChannel ctx
        pendingRef = pendingThreads ctx

    pending <- liftIO $ readIORef pendingRef
    case pending of
        [] -> return ()
        _ ->  do
            mev <- liftIO $ atomically $ tryReadTChan cchan
            case mev of
                Nothing -> return ()
                Just ev -> do
                    (p, e) <- processOneEvent ev pending
                    liftIO $ writeIORef pendingRef p
                    maybe (return ()) throwM e
                    tryReclaimZombies ctx

waitForOneEvent :: (MonadIO m, MonadThrow m) => Context -> m ()
waitForOneEvent ctx = do
    -- XXX assert pending must have at least one element
    -- assert that the tid is found in our list
    let cchan = childChannel ctx
        pendingRef = pendingThreads ctx

    ev <- liftIO $ atomically $ readTChan cchan
    pending <- liftIO $ readIORef pendingRef
    (p, e) <- processOneEvent ev pending
    liftIO $ writeIORef pendingRef p
    maybe (return ()) throwM e

-- XXX this is not a real semaphore as it does not really block on wait,
-- instead it returns whether the value is zero or non-zero.
--
waitQSemB :: IORef Int -> IO Bool
waitQSemB   sem = atomicModifyIORef sem $ \n ->
                    if n > 0
                    then (n - 1, True)
                    else (n, False)

signalQSemB :: IORef Int -> IO ()
signalQSemB sem = atomicModifyIORef sem $ \n -> (n + 1, ())

-- Allocation of threads
--
-- global thread limit
-- thread fan-out i.e. per thread children limit
-- min per thread allocation to avoid starvation
--
-- dynamic adjustment based on the cost, speed of consumption, cpu utilization
-- etc. We need to adjust the limits based on cost, throughput and latencies.
--
-- The event producer thread must put the work on a work-queue and the child
-- threads can pick it up from there. But if there is just one consumer then it
-- may not make sense to have a separate producer unless the producing cost is
-- high.
--

forkFinally1 :: (MonadIO m, MonadBaseControl IO m)
    => Context -> (Either SomeException () -> IO ()) -> StateT Context m ThreadId
forkFinally1 ctx preExit =
    EL.mask $ \restore ->
        liftBaseWith $ \runInIO -> forkIO $ do
            _ <- runInIO $ EL.try (restore (runContext ctx))
                           >>= liftIO . preExit
            return ()

-- | Run a given context in a new thread.
--
forkContext :: (MonadBaseControl IO m, MonadIO m, MonadThrow m)
    => Context -> StateT Context m ()
forkContext context = do
    child <- childContext context
    tid <- forkFinally1 child (beforeExit child)
    updatePendingThreads context tid

    where

    updatePendingThreads :: (MonadIO m, MonadThrow m)
        => Context -> ThreadId -> m ()
    updatePendingThreads ctx tid = do
        -- update the new thread before reclaiming zombies so that if it exited
        -- already reclaim finds it in the list and does not panic.
        liftIO $ modifyIORef (pendingThreads ctx) $ (\ts -> tid:ts)
        tryReclaimZombies ctx

    childContext ctx = do
        pendingRef <- liftIO $ newIORef []
        chan <- liftIO $ atomically newTChan
        -- shares the threadCredit of the parent by default
        return $ ctx
            { parentChannel  = Just (childChannel ctx)
            , pendingThreads = pendingRef
            , childChannel = chan
            }

    beforeExit ctx res = do
        tid <- myThreadId
        r <- case res of
            Left e -> do
                dbg $ "beforeExit: " ++ show tid ++ " caught exception"
                liftIO $ readIORef (pendingThreads ctx) >>= mapM_ killThread
                return (Just e)
            Right _ -> waitForChildren ctx

        -- We are guaranteed to have a parent because we are forked.
        let p = fromJust (parentChannel ctx)
        signalQSemB (threadCredit ctx)
        liftIO $ atomically $ writeTChan p (ChildDone tid r)

-- | Decide whether to resume the context in the same thread or a new thread
--
canFork :: Context -> IO Bool
canFork context = do
    gotCredit <- liftIO $ waitQSemB (threadCredit context)
    case gotCredit of
        False -> do
            pending <- liftIO $ readIORef $ pendingThreads context
            case pending of
                [] -> return False
                _ -> do
                        -- XXX If we have unreclaimable child threads e.g.
                        -- infinite loop, this is going to deadlock us. We need
                        -- special handling for those cases. Add those to
                        -- unreclaimable list? And always execute them in an
                        -- async thread, cannot use sync for those.
                        waitForOneEvent context
                        canFork context
        True -> return True

-- | Resume a captured context with a given action. The context may be resumed
-- in the same thread or in a new thread depending on the synch parameter and
-- the current thread quota.
--
resumeContextWith :: (MonadBaseControl IO m, MonadIO m, MonadThrow m)
    => Context          -- the context to resume
    -> Bool             -- force synchronous
    -> (Context -> AsyncT m (StreamData a)) -- the action to execute in the resumed context
    -> StateT Context m ()
resumeContextWith context synch action = do
    let ctx = setContextMailBox context (action context)
    can <- liftIO $ canFork context
    case can && (not synch) of
        False -> runContext ctx -- run synchronously
        True -> forkContext ctx

instance Read SomeException where
  readsPrec _n str = [(SomeException $ ErrorCall s, r)]
    where [(s , r)] = read str

-- | 'StreamData' represents a task in a task stream being generated.
data StreamData a =
      SMore a               -- ^ More tasks to come
    | SLast a               -- ^ This is the last task
    | SDone                 -- ^ No more tasks, we are done
    | SError SomeException  -- ^ An error occurred
    deriving (Typeable, Show,Read)

-- The current model is to start a new thread for every task. The input is
-- provided at the time of the creation and therefore no synchronization is
-- needed compared to a pool of threads contending to get the input from a
-- channel. However the thread creation overhead may be more than the
-- synchronization cost?
--
-- When the task is over the outputs need to be collected and that requires
-- synchronization irrespective of a thread pool model or per task new thread
-- model.
--
-- XXX instead of starting a new thread every time, reuse the existing child
-- threads and send them work via a shared channel. When there is no more work
-- available we need a way to close the channel and wakeup all waiters so that
-- they can go away rather than waiting indefinitely.
--

-- Housekeeping, invoked after spawning of all child tasks is done and the
-- parent task needs to terminate. Either the task is fully done or we handed
-- it over to another thread, in any case the current thread is done.

spawningParentDone :: MonadIO m => StateT Context m (Maybe (StreamData a))
spawningParentDone = do
    loc <- getLocation
    when (loc /= RemoteNode) $ setLocation WaitingParent
    return Nothing

-- | Captures the state of the current computation at this point, starts a new
-- thread, passing the captured state, runs the argument computation in the new
-- thread, returns its value and continues the computation from the capture
-- point. The end result is as if this function just returned the value
-- generated by the argument computation albeit in a new thread.
--
-- If a new thread cannot be created then the computation is run in the same
-- thread, but the functional behavior remains the same.

spawnAsyncT :: (MonadIO m, MonadBaseControl IO m, MonadThrow m)
    => (Context -> AsyncT m (StreamData a))
    -> AsyncT m (StreamData a)
spawnAsyncT func = AsyncT $ do
    val <- takeContextMailBox
    case val of
        -- Child task
        Right x -> runAsyncT x

        -- Spawning parent
        Left ctx -> do
            resumeContextWith ctx False func

            -- If we started the task asynchronously in a new thread then the
            -- parent thread reaches here, immediately after spawning the task.
            --
            -- However, if the task was executed synchronously then we will
            -- reach after it is completely done.
            spawningParentDone

-- | Execute the specified IO action, resume the saved context returning the
-- output of the io action, continue this in a loop until the ioaction
-- indicates that its done.

loopContextWith ::  (MonadIO m, MonadBaseControl IO m, MonadThrow m)
    => IO (StreamData a) -> Context -> AsyncT m (StreamData a)
loopContextWith ioaction context = AsyncT $ do
    -- Note that the context that we are resuming may have been passed from
    -- another thread, therefore we must inherit thread control related
    -- parameters from the current context.
    curCtx <- get
    loop context
        { parentChannel  = parentChannel curCtx
        , pendingThreads = pendingThreads curCtx
        , childChannel   = childChannel curCtx
        }

    where

    loop ctx = do
        streamData <- liftIO $ ioaction `catch`
                \(e :: SomeException) -> return $ SError e

        let resumeCtx synch = resumeContextWith ctx synch $ \_ ->
                return streamData

        case streamData of
            SMore _ -> resumeCtx False >> loop ctx
            _       -> resumeCtx True  >> spawningParentDone

-- | Run an IO action one or more times to generate a stream of tasks. The IO
-- action returns a 'StreamData'. When it returns an 'SMore' or 'SLast' a new
-- task is triggered with the result value. If the return value is 'SMore', the
-- action is run again to generate the next task, otherwise task creation
-- stops.
--
-- Unless the maximum number of threads (set with 'threads') has been reached,
-- the task is generated in a new thread and the current thread returns a void
-- task.
parallel  :: (MonadIO m, MonadBaseControl IO m, MonadThrow m)
    => IO (StreamData a) -> AsyncT m (StreamData a)
parallel ioaction = spawnAsyncT (loopContextWith ioaction)

-- | An task stream generator that produces an infinite stream of tasks by
-- running an IO computation in a loop. A task is triggered carrying the output
-- of the computation. See 'parallel' for notes on the return value.
waitEvents :: (MonadIO m, MonadBaseControl IO m, MonadThrow m)
    => IO a -> AsyncT m a
waitEvents io = do
  mr <- parallel (SMore <$> io)
  case mr of
    SMore  x -> return x
 --   SError e -> back e

-- | Run an IO computation asynchronously and generate a single task carrying
-- the result of the computation when it completes. See 'parallel' for notes on
-- the return value.
async  :: (MonadIO m, MonadBaseControl IO m, MonadThrow m)
    => IO a -> AsyncT m a
async io = do
  mr <- parallel (SLast <$> io)
  case mr of
    SLast  x -> return x
  --  SError e -> back   e

-- | Force an async computation to run synchronously. It can be useful in an
-- 'Alternative' composition to run the alternative only after finishing a
-- computation.  Note that in Applicatives it might result in an undesired
-- serialization.
sync :: MonadIO m => AsyncT m a -> AsyncT m a
sync x = AsyncT $ do
  setLocation RemoteNode
  r <- runAsyncT x
  setLocation Worker
  return r

-- | An task stream generator that produces an infinite stream of tasks by
-- running an IO computation periodically at the specified time interval. The
-- task carries the result of the computation.  A new task is generated only if
-- the output of the computation is different from the previous one.  See
-- 'parallel' for notes on the return value.
sample :: (Eq a, MonadIO m, MonadBaseControl IO m, MonadThrow m)
    => IO a -> Int -> AsyncT m a
sample action interval = do
  v    <- liftIO action
  prev <- liftIO $ newIORef v
  waitEvents (loop action prev) <|> async (return v)
  where loop act prev = loop'
          where loop' = do
                  threadDelay interval
                  v  <- act
                  v' <- readIORef prev
                  if v /= v' then writeIORef prev v >> return v else loop'

-- | Make a transient task generator from an asynchronous callback handler.
--
-- The first parameter is a callback. The second parameter is a value to be
-- returned to the callback; if the callback expects no return value it
-- can just be a @return ()@. The callback expects a setter function taking the
-- @eventdata@ as an argument and returning a value to the callback; this
-- function is supplied by 'react'.
--
-- Callbacks from foreign code can be wrapped into such a handler and hooked
-- into the transient monad using 'react'. Every time the callback is called it
-- generates a new task for the transient monad.
--
{-
react
  :: (Monad m, MonadIO m)
  => ((eventdata ->  m response) -> m ())
  -> IO  response
  -> AsyncT m eventdata
react setHandler iob = AsyncT $ do
        context <- get
        case event context of
          Nothing -> do
            lift $ setHandler $ \dat ->do
              resume (updateContextEvent context dat)
              liftIO iob
            loc <- getLocation
            when (loc /= RemoteNode) $ setLocation WaitingParent
            return Nothing

          j@(Just _) -> do
            put context{event=Nothing}
            return $ unsafeCoerce j

-}

------------------------------------------------------------------------------
-- Controlling thread quota
------------------------------------------------------------------------------

-- XXX Should n be Word32 instead?
-- | Runs a computation under a given thread limit.  A limit of 0 means new
-- tasks start synchronously in the current thread.  New threads are created by
-- 'parallel', and APIs that use parallel.
threads :: MonadIO m => Int -> AsyncT m a -> AsyncT m a
threads n process = AsyncT $ do
   oldCr <- gets threadCredit
   newCr <- liftIO $ newIORef n
   modify $ \s -> s { threadCredit = newCr }
   r <- runAsyncT $ process
        <** (AsyncT $ do
            modify $ \s -> s { threadCredit = oldCr }
            return (Just ())
            ) -- restore old credit
   return r

{-
-- | Run a "non transient" computation within the underlying state monad, so it
-- is guaranteed that the computation neither can stop nor can trigger
-- additional events/threads.
noTrans :: Monad m => StateM m x -> AsyncT m x
noTrans x = AsyncT $ x >>= return . Just

-- This can be used to set, increase or decrease the existing limit. The limit
-- is shared by multiple threads and therefore needs to modified atomically.
-- Note that when there is no limit the limit is set to maxBound it can
-- overflow with an increment and get reduced instead of increasing.
-- XXX should we use a Maybe instead? Or use separate inc/dec/set APIs to
-- handle overflow properly?
--
-- modifyThreads :: MonadIO m => (Int -> Int) -> AsyncT m ()
-- modifyThreads f =
-}

------------------------------------------------------------------------------
-- Running the monad
------------------------------------------------------------------------------

-- | Run an 'AsyncT m' computation and collect the results generated by each
-- thread of the computation in a list.
waitAsync :: forall m a b. (MonadIO m, MonadCatch m)
    => (a -> AsyncT m a) -> AsyncT m a -> m ()
waitAsync finalizer m = do
    childChan  <- liftIO $ atomically newTChan
    pendingRef <- liftIO $ newIORef []
    credit     <- liftIO $ newIORef maxBound

    let ctx = initContext (empty :: AsyncT m a) childChan pendingRef credit
                  finalizer

    r <- try $ runStateT (runAsyncT $ m >>= finalizer) ctx

    case r of
        Left (exc :: SomeException) -> do
            liftIO $ readIORef pendingRef >>= mapM_ killThread
            throwM exc
        Right _ -> do
            e <- waitForChildren ctx
            case e of
                Just (exc :: SomeException) -> throwM exc
                Nothing -> return ()

-- TBD throttling of producer based on conumption rate.

-- | Invoked to store the result of the computation in the context and finish
-- the computation when the computation is done
gatherResult :: MonadIO m => IORef [a] -> a -> AsyncT m a
gatherResult ref r = do
    liftIO $ atomicModifyIORef ref $ \rs -> (r : rs, rs)
    mzero

-- | Run an 'AsyncT m' computation and collect the results generated by each
-- thread of the computation in a list.
gather :: forall m a. (MonadIO m, MonadCatch m)
    => AsyncT m a -> m [a]
gather m = do
    resultsRef <- liftIO $ newIORef []
    waitAsync (gatherResult resultsRef) m
    liftIO $ readIORef resultsRef

-- | Run an 'AsyncT m' computation, wait for it to finish and discard the
-- results.
wait :: forall m a. (MonadIO m, MonadCatch m)
    => AsyncT m a -> m ()
wait m = waitAsync (const mzero) m
