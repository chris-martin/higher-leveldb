{-# LANGUAGE OverloadedStrings, GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances, ConstraintKinds #-}

module Database.LevelDB.Higher
    ( get, put, delete
    , scan, ScanQuery(..), queryItems, queryList, queryBegins
    , MonadLevelDB, LevelDBT, LevelDB, runLevelDB, withKeySpace
    , Key, Value, KeySpace
    ) where


import           Control.Monad.Reader

import           Data.Int                         (Int32)
import           Data.Monoid                      ((<>))


import           Control.Applicative              (Applicative)
import           Control.Arrow                    ((&&&))
import           Control.Monad.Base               (MonadBase(..))

import           Control.Concurrent.MVar.Lifted

import qualified Data.ByteString                   as BS
import           Data.ByteString                   (ByteString)
import           Data.Serialize                    (encode, decode)

import           Data.Default                      (def)
import qualified Database.LevelDB                  as LDB
import           Database.LevelDB                  hiding (put, get, delete)
import           Control.Monad.Trans.Resource      (ResourceT
                                                   , MonadUnsafeIO
                                                   , MonadThrow
                                                   , MonadResourceBase)

type Key = ByteString
type Value = ByteString
type KeySpace = ByteString
type KeySpaceId = ByteString
type Item = (Key, Value)

-- | Reader-based data context API
--
-- Context contains database handle and KeySpace
data DBContext = DBC { dbcDb :: DB
                     , dbcKsId :: KeySpaceId
                     , dbcSyncMV :: MVar Int32
                     }
instance Show (DBContext) where
    show = (<>) "KeySpaceID: " . show . dbcKsId




-- | LevelDBT Transformer provides a context for database operations
-- provided in this module.
--
-- This transformer has the same constraints as 'ResourceT' as it wraps
-- 'ResourceT' along with a 'DBContext' 'Reader'.
--
-- If you aren't building a custom monad stack you can just use the LevelDB alias.
--
-- Use 'runLevelDB'
newtype LevelDBT m a
        =  LevelDBT { unLevelDBT :: ReaderT DBContext (ResourceT m) a }
            deriving ( Functor, Applicative, Monad
                     , MonadIO, MonadReader DBContext
                     , MonadThrow )

-- | MonadLevelDB class basically just captures all the constraints required
-- when defining a custom monad stack or defining functions you want to work
-- with any LevelDBT derived stack
class ( MonadThrow m
      , MonadUnsafeIO m
      , MonadIO m
      , Applicative m
      , MonadReader DBContext m
      , MonadResource m
      , MonadBase IO m)
      => MonadLevelDB m

instance (MonadResourceBase m) => MonadBase IO (LevelDBT m) where
    liftBase = lift . liftBase

instance (MonadResourceBase m) => MonadLevelDB (LevelDBT m)

instance MonadTrans LevelDBT where
    lift = LevelDBT . lift . lift

instance (MonadResourceBase m) => MonadResource (LevelDBT m) where
    liftResourceT = LevelDBT . liftResourceT

instance Show (LevelDBT m a) where
    show = asks show

-- | alias for LevelDBT IO - useful if you aren't building a custom stack
type LevelDB a = LevelDBT IO a

-- |Build a context and execute the actions.
-- Specify a filepath to use for the database (will create if not there).
-- Also specify an application-defined keyspace in which keys
-- will be guaranteed unique
runLevelDB :: (MonadResourceBase m) => FilePath -> KeySpace -> LevelDBT m a -> m a
runLevelDB dbPath ks ctx = runResourceT $ do
    db <- openDB dbPath
    mv <- newMVar 0
    ksId <- withSystemContext db mv $ getKeySpaceId ks
    runReaderT (unLevelDBT ctx) (DBC db ksId mv)
  where
    openDB path =
        LDB.open path
            LDB.defaultOptions{LDB.createIfMissing = True, LDB.cacheSize= 2048}
    withSystemContext db mv sctx =
        runReaderT (unLevelDBT sctx) $ DBC db systemKeySpaceId mv

-- | Override keyspace with a local keyspace for an (block) action(s)
--
withKeySpace :: (MonadLevelDB m) => KeySpace -> m a -> m a
withKeySpace ks a = do
    ksId <- getKeySpaceId ks
    local (\dbc -> dbc { dbcKsId = ksId}) a

put :: (MonadLevelDB m) => Key -> Value -> m ()
put k v = do
    (db, ksId) <- asks $ dbcDb &&& dbcKsId
    let packed = ksId <> k
    LDB.put db def packed v

get :: (MonadLevelDB m) => Key -> m (Maybe Value)
get k = do
    (db, ksId) <- getDB
    let packed = ksId <> k
    LDB.get db def packed

delete :: (MonadLevelDB m) => Key -> m ()
delete k = do
    (db, ksId) <- getDB
    let packed = ksId <> k
    LDB.delete db def packed

-- | Structure containing functions used within the 'scan' function
data ScanQuery a b = ScanQuery {
                         -- | starting value for fold/reduce
                         scanInit :: b

                         -- | scan will continue until this returns false
                       , scanWhile :: Key -> Item -> b -> Bool

                         -- | map or transform an item before it is reduced/accumulated
                       , scanMap ::  Item -> a

                         -- | filter function - return 'False' to leave
                         -- this 'Item' out of the result
                       , scanFilter :: Item -> Bool

                         -- | accumulator/fold function e.g. (:)
                       , scanReduce :: a -> b -> b
                       }

-- | a basic ScanQuery helper that defaults scanWhile to continue while
-- the key argument supplied to scan matches the beginning of the key returned
-- by the iterator
--
-- requires an 'scanInit', a 'scanMap' and a 'scanReduce' function
queryBegins :: ScanQuery a b
queryBegins = ScanQuery
                   { scanWhile = \ prefix (nk, _) _ ->
                                          BS.length nk >= BS.length prefix
                                          && BS.take (BS.length nk -1) nk == prefix
                   , scanInit = error "No scanInit provided."
                   , scanMap = error "No scanMap provided."
                   , scanFilter = const True
                   , scanReduce = error "No scanReduce provided."
                   }

-- | a ScanQuery helper that will produce the list of items as-is
-- while the key matches as queryBegins
--
-- does not require any functions though they could be substituted
queryItems :: ScanQuery Item [Item]
queryItems = queryBegins { scanInit = []
                       , scanMap = id
                       , scanReduce = (:)
                       }

-- | a ScanQuery helper with defaults for a list result; requires a map function
--
-- while the key matches as queryBegins
queryList :: ScanQuery a [a]
queryList  = queryBegins { scanInit = []
                       , scanFilter = const True
                       , scanReduce = (:)
                       }

-- | Scan the keyspace, applying functions and returning results
-- Look at the documentation for 'ScanQuery' for more information.
--
-- This is essentially a fold left that will run until the 'scanWhile'
-- condition is met or the iterator is exhausted. All the results will be
-- copied into memory before the function returns.
scan :: (MonadLevelDB m)
     => Key  -- ^ Key at which to start the scan
     -> ScanQuery a b
     -> m b
scan k scanQuery = do
    (db, ksId) <- getDB
    withIterator db def $ doScan (ksId <> k)
  where
    doScan prefix iter = do
        iterSeek iter prefix
        applyIterate initV
      where
        readItem = do
            nk <- iterKey iter
            nv <- iterValue iter
            return (fmap (BS.drop 4) nk, nv) --unkeyspace
        applyIterate acc = do
            item <- readItem
            case item of
                (Just nk, Just nv) ->
                    if whileFn (nk, nv) acc then do
                        iterNext iter
                        items <- applyIterate acc
                        return $ if filterFn (nk, nv) then
                                     reduceFn (mapFn (nk, nv)) items
                                 else items
                    else return acc
                _ -> return acc
    initV = scanInit scanQuery
    whileFn = scanWhile scanQuery k
    mapFn = scanMap scanQuery
    filterFn = scanFilter scanQuery
    reduceFn = scanReduce scanQuery

getDB :: (MonadLevelDB m) => m (DB, KeySpaceId)
getDB = asks $ dbcDb &&& dbcKsId

defaultKeySpaceId :: KeySpaceId
defaultKeySpaceId = "\0\0\0\0"

systemKeySpaceId ::  KeySpaceId
systemKeySpaceId = "\0\0\0\1"

getKeySpaceId :: (MonadLevelDB m) => KeySpace -> m KeySpaceId
getKeySpaceId ks
    | ks == ""  = return defaultKeySpaceId
    | ks == "system" = return systemKeySpaceId
    | otherwise = do
        findKS <- get $ "keyspace:" <> ks
        case findKS of
            (Just foundId) -> return foundId
            Nothing -> do -- define new KS
                nextId <- incr "max-keyspace-id"
                put ("keyspace:" <> ks) nextId
                return nextId
  where
    incr k = do
        mv <- takeMVarDBC
        curId <- case mv of
            0 -> initKeySpaceIdMV k >> takeMVarDBC
            n -> return n
        let nextId = curId + 1
        put k $ encode nextId
        putMVarDBC nextId
        return $ encode curId
    initKeySpaceIdMV k = do
        findMaxId <- get k
        case findMaxId of
            (Just found) -> putMVarDBC $ decodeKsId found
            Nothing      -> putMVarDBC 2 -- first user keyspace
    putMVarDBC v = asks dbcSyncMV >>= flip putMVar v
    takeMVarDBC = asks dbcSyncMV >>= takeMVar
    decodeKsId bs =
        case decode bs of
            Left e -> error $
                "Error decoding Key Space ID: " <> show bs <> "\n" <> e
            Right i -> i :: Int32
