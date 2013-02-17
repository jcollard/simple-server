{-# LANGUAGE ConstraintKinds #-} 

{-|
The goal of SimpleServer, as its name implies, is to make it easy to build
simple message passing servers by puting a layer between the programmer and
the concurrent operations between it and the network layer connecting
it to multiple clients.
-}
module Network.SimpleServer(-- * Type Synonyms
                            -- $types
                            ConnectionHandler,
                            DisconnectHandler,
                            CmdHandler,
                            -- * Server Construction
                            -- $server
                            Server(),
                            new, 
                            addCommand,
                            start, 
                            stop, 
                            -- * Client Interaction
                            -- $client
                            ClientConn(),
                            cid,
                            lookup,
                            modify,
                            respond, 
                            broadcast, 
                            disconnect,
                            clientList) where

import Control.Concurrent hiding(modifyMVar)
import qualified Control.Concurrent.Lock as Lock
import Control.Concurrent.MVar hiding(modifyMVar)
import Control.Concurrent.Thread.Delay
import Control.Exception
import Control.Monad
import qualified Data.ByteString.Char8 as ByteS
import Data.Foldable(toList)
import qualified Data.HashTable.IO as HT
import Data.IORef
import Data.Time.Clock
import qualified Data.Sequence as Seq
import qualified Network as Net
import qualified Network.Socket as Net(close)
import System.IO(Handle, hSetBuffering, BufferMode(NoBuffering))
import Prelude hiding(lookup)

{-| A server may have any number of CmdHandlers. When a CmdHandler is called it
is passed a list of strings representing the message the server received, the
server that received it, and the client that send the message. The first
part element of the list is the string that triggered the CmdHandler.
-}
type CmdHandler = [String] -> Server -> ClientConn -> IO ()

{-| Each server has one ConnectionHandler that is called each time a client connects to the server.
-}
type ConnectionHandler = Server -> ClientConn -> IO ()

{-|A DisconnectHandler is called each time a client is disconnected from the server.
-}
type DisconnectHandler = Server -> ClientConn -> IO ()

{-|
Describes a Clients connection and provides an interface for
storing data associated with the client. Each client will be given
a unique cid and are Eq if their cid's are Eq.

A ClientConn comes packaged with two functions for storing additional
information in Strings, lookup and modify. The lookup function
takes a key and returns the current value of the key or the empty
string if it has never been set. The modify function
takes a key and value and updates it such that the next call to
lookup with that key will return the value provided.
-}
data ClientConn = ClientConn { 
  -- | The Unique ID for this client
  cid       :: Integer,
  -- | Looks up a property for this client. By default, all properties are the empty string.
  lookup    :: (String -> IO String),  
  -- | Modifies a client property. Given a property string, and a value string, the next call to lookup for the given property will result in the value.
  modify    :: (String -> String -> IO ()),
  chandle   :: Handle,
  host      :: Net.HostName,
  pid       :: Net.PortNumber,
  msgList  :: List String,
  dead      :: MVar Bool,
  timestamp :: TimeStamp,
  tid       :: MVar (ThreadId, ThreadId),
  serv      :: Server}

instance Eq ClientConn where
  (==) c0 c1 = (cid c0) == (cid c1)

-- |A Simple Server
data Server = Server { port       :: Net.PortID, 
                       socket     :: IORef (Maybe Net.Socket), 
                       clients    :: List ClientConn,
                       cmdList    :: List Message,
                       lastclean  :: TimeStamp,
                       timeout    :: NominalDiffTime,
                       lock       :: Lock.Lock,
                       cmdTable   :: CmdTable,
                       nextID     :: MVar Integer,
                       cHandler   :: ConnectionHandler,
                       dHandler   :: DisconnectHandler,
                       threads    :: MVar (ThreadId, ThreadId)}





{-|
Creates a new server with the specified ConnectionHandler and DisconnectHandler.
On a call to start, the server will attempt to connect on the specified Port.
If a client does not talk to a server for more than 60 seconds
it will be disconnected.
-}
new :: ConnectionHandler -> DisconnectHandler -> Int -> IO Server
new cHandler dHandler pid = do
  socket   <- newIORef Nothing
  clients  <- emptyList
  cmdList <- emptyList
  time <- getCurrentTime
  lastClean <- newMVar time
  serverLock <- Lock.new
  let allowed = 60
  cmdTable <- HT.new
  nextID <- newMVar 0
  threads <- newEmptyMVar
  return $ Server (Net.PortNumber $ fromIntegral pid) socket clients cmdList lastClean allowed serverLock cmdTable nextID cHandler dHandler threads

{-|
Given a server, a command, and a command handler, adds the command to the
server. If the command already exists, it will be overwritten.
-}
addCommand :: Server -> String -> CmdHandler -> IO ()
addCommand server cmd handler = HT.insert (cmdTable server) cmd handler

{-|
Starts a server if it is currently not started. Otherwise, does nothing. The
server will be started on a new thread and control will be returned to the
thread that called this function.
-}
start :: Server -> IO ()
start server = Net.withSocketsDo $ do
  maybeSocket <- readIORef $ socket server
  case maybeSocket of
    Nothing -> do 
      s <- try $ Net.listenOn (port server) :: IO (Either IOException Net.Socket)
      case s of 
        Left e -> debugLn' (lock server) $ "The server could not be started: " ++ (show e)
        Right s -> do
          writeIORef (socket server) (Just s)
          rt <- forkIO $ runServer server
          at <- forkIO $ acceptCon server s
          putMVar (threads server) (rt, at)
          return ()
    Just s -> return ()

{-|
Stops a server if it is running sending a disconnect message
to all clients and killing any threads that have been spawned. 
Otherwise, does nothing.
Any shutdown operations should be run before this is called. 
-}
stop :: Server -> IO ()
stop server = Net.withSocketsDo $ do
  maybeSocket <- readIORef $ socket server
  case maybeSocket of
    Nothing -> return ()
    Just s -> do
      clist <- takeAll $ clients server
      mapM_ (disconnect' server) (toList clist)
      (rt, at) <- takeMVar (threads server)
      killThread rt
      killThread at
      Net.close s
      writeIORef (socket server) Nothing

{-|
Adds a message to the clients message queue to be handled eventually.
-}
respond :: ClientConn -> String -> IO ()
respond client string = put (msgList client) string

{-|
Adds a message to all clients message queue to be handled eventually.
-}
broadcast :: Server -> String -> IO ()
broadcast server string = do
  debugLn' (lock server) "Reading client list"
  q <- readAll (clients server)
  debugLn' (lock server) "Processing client list"
  mapM_ ((flip put string) . msgList) q
  debugLn' (lock server) "Message queued."

{-|
Disconnects the client if they are still connected to the server.
-}
disconnect :: ClientConn -> IO ()
disconnect client = do
  d <- readMVar (dead client)
  if d then return () else do
    swapMVar (dead client) True
    clean (serv client)

{-|
Returns a list of all clients that are currently connected to the server
-}
clientList :: Server -> IO [ClientConn]
clientList = readAll . clients


--------------------------------------
-- Helper Functions and Types Begin --
--------------------------------------

type List a = MVar (Seq.Seq a)
type TimeStamp = MVar UTCTime
type CmdTable = HT.BasicHashTable String CmdHandler
type UserTable = HT.BasicHashTable String String


data Message = Message { cmd    :: String,
                         client :: ClientConn } deriving Eq

{-|              
Creates a new client connection
-}
newConn :: Integer -> Handle -> Net.HostName -> Net.PortNumber -> Server -> IO ClientConn
newConn id handle host pid server = do
  queue <- emptyList
  dead' <- newMVar False
  tid <- newEmptyMVar
  timestamp <- newEmptyMVar
  table <- HT.new
  let lookup = safeLookup (lock server) table
      modify = safeModify (lock server) table
  return $ ClientConn id lookup modify handle host pid queue dead' timestamp tid server

safeLookup :: Lock.Lock -> UserTable -> (String -> IO String)
safeLookup lock usertable = (\key -> do
                                Lock.acquire lock
                                val <- HT.lookup usertable key
                                Lock.release lock
                                return $ case val of
                                    Nothing -> ""
                                    Just x -> x)

safeModify :: Lock.Lock -> UserTable -> (String -> String -> IO ())
safeModify lock usertable = (\key val -> do
                                Lock.acquire lock
                                HT.insert usertable key val
                                Lock.release lock)



{-| 
The main loop for the server. Checks to see if the
server has started, if it has it checks for any clients
who need to be disconnected then processes any commands in its queue.
Every 30 seconds, the server will check to see if a client has disconnected
or timed out and remove those clients from the client list.
After processing the loop continues until the server is stopped.
If there are no commands, it will wait approx. 1/10th of a second
before continuing.
-}
runServer :: Server -> IO ()
runServer server = Net.withSocketsDo $ do
  maybeSocket <- readIORef $ socket server
  case maybeSocket of
    Nothing -> return ()
    Just _ -> do
      checkClean server
      cmds <- takeAll (cmdList server)
      if (cmds == []) 
        then delay (1000*100) 
        else do
          debugLn' (lock server) "Processing Commands..."
          mapM_ (processCommand server) cmds
          debugLn' (lock server) "Done."
      runServer server

{-|
Using a servers command table, processess the a message. If
the message cannot be processed, a message is added to its response queue
-}
processCommand :: Server -> Message -> IO ()
processCommand server msg = do
  let commands = words (cmd msg)
  if commands == [] 
    then return ()
    else do
      maybeFunction <- HT.lookup (cmdTable server) (head commands)
      case maybeFunction of
        Nothing -> do
          debugLn' (lock server) $ "Could not process command: " ++ (cmd msg)
          put (response_queue msg) ("Invalid command: " ++ (cmd msg))
        Just f -> f commands server (client msg)
      where response_queue = msgList . client
{-|
Checks for dead or timed out clients and removes them.
-}
checkClean :: Server -> IO ()
checkClean server = do
  time <- getCurrentTime
  last <- readMVar (lastclean server)
  let passed = diffUTCTime time last
      allowed = timeout server
  if (passed > allowed) 
    then do
      swapMVar (lastclean server) time
      clean server
    else return ()

clean :: Server -> IO ()
clean server = do
  let allowed = timeout server
  clist <- takeMVar (clients server)
  (newCList, removed) <- filterM' (timedout server allowed) clist
  putMVar (clients server) (Seq.fromList newCList)
  mapM_ (disconnect' server) removed


-- Helper function for filtering Seq with a pred of a -> IO Bool
filterM' :: Monad m => (a -> m Bool) -> Seq.Seq a -> m ([a],[a])
filterM' pred seq = do
  ls <- filterM pred (toList seq)
  ls' <- filterM not' (toList seq)
  return (ls, ls')
  where not' a = do
          val <- pred a
          return $ not val

-- Helper that checks if a client is timed out or marked dead. If they are
-- they are sent a disconnect message and removed from the  
-- client list
timedout :: Server -> NominalDiffTime -> ClientConn -> IO Bool
timedout server allowed client = do
  time <- getCurrentTime
  last <- readMVar (timestamp client)
  dead' <- readMVar (dead client)
  let passed = diffUTCTime time last
  return $ not $ (passed > allowed) || (dead' == True)

-- Sends a disconnect message to a client, marks it dead
-- and kills any associated threads
disconnect' :: Server -> ClientConn -> IO ()
disconnect' server client = do
  (dHandler server) server client
  flush server client
  (wio,rio) <- readMVar $ tid client
  killThread wio
  killThread rio
  swapMVar (dead client) True
  return ()

flush :: Server -> ClientConn -> IO ()
flush server client = do
  messages <- takeAll $ msgList client
  mapM_ (hPutStrLn (chandle client)) messages

{-|
Accepts a connection and adds it to the clients list
-}
acceptCon :: Server -> Net.Socket -> IO ()
acceptCon server sock = do
  (handle, host, pid) <- Net.accept sock
  hSetBuffering handle NoBuffering
  id <- takeMVar (nextID server)
  putMVar (nextID server) (id+1)
  conn <- newConn id handle host pid server
  time <- getCurrentTime
  putMVar (timestamp conn) time
  put (clients server) conn
  wio <- forkIO $ writeClient conn
  rio <- forkIO $ readClient conn (cmdList server)
  putMVar (tid conn) (wio,rio)
  (cHandler server) server conn
  acceptCon server sock
  
{-
The main loop for receiving input from a client.
Read a whole string input, create a message, queue it for processing, repeat
-}
readClient :: ClientConn -> List Message -> IO ()
readClient client queue = do
  either <- try $ hGetLine (chandle client) :: IO (Either IOException String)
  case either of
    Left e -> do 
      swapMVar (dead client) True
      return ()
    Right val -> do
      time <- getCurrentTime
      swapMVar (timestamp client) time
      put queue (Message val client)
      readClient client queue
{-
The main loop for sending output to a client. All messages that are queued
to be sent, are sent. If the queue was empty, the thread sleeps for approx 1/10th
a second
-}
writeClient :: ClientConn -> IO () 
writeClient client = do
  queue <- takeAll (msgList client)
  if queue == [] 
    then do 
      delay (1000*100)
      writeClient client
    else do
      debugLn' (lock (serv client)) "Client List non-empty. Writing to client."
      either <- try $ mapM_ (hPutStrLn (chandle client)) queue :: IO (Either IOException ())
      case either of
        Left e -> do
          debugLn' (lock (serv client)) $ "Could not read from handle: " ++ (show e)
          swapMVar (dead client) True
          return ()
        Right _ -> writeClient client


-- Debugging putStrLn that takes a lock such that
-- the output is readable.
putStrLn' :: Lock.Lock -> String -> IO ()
putStrLn' lock string = do
  Lock.acquire lock
  putStrLn string
  Lock.release lock
  
hPutStrLn :: Handle -> String -> IO ()
hPutStrLn handle string = ByteS.hPutStrLn handle (ByteS.pack string)

hGetLine :: Handle -> IO String
hGetLine handle = do
  line <- ByteS.hGetLine handle
  return $ ByteS.unpack line

debug = False

debugLn' :: Lock.Lock -> String -> IO ()
debugLn' lock str = if debug then putStrLn' lock str else return ()

emptyList :: IO (List a)
emptyList = newMVar Seq.empty

takeAll :: List a -> IO [a]
takeAll queue = do
  q <- swapMVar queue Seq.empty
  return $ toList q

readAll :: List a -> IO [a]
readAll queue = do
  q <- readMVar queue
  return $ toList q

modifyMVar :: MVar a -> (a -> a) -> IO ()
modifyMVar mvar f = do
  el <- takeMVar mvar
  putMVar mvar (f el)

put :: List a -> a -> IO ()
put queue el = modifyMVar queue (Seq.|> el)  

{- $types
To start using simple server, the programmer simply needs to define
the callbacks that occur when a client connects, disconnects, or sends a message
to the server. These three callbacks have type synonyms defined: 'ConnectionHandler', 'DisconnectHandler', and 'CmdHandler'. 

To create a 'ConnectionHandler' that notifies all clients that a new client
has connected and respond to the new client with a simple welcome message
one might define the following:

@
simpleConnect :: ConnectionHandler
simpleConnect server client = do
  broadcast server \"A new user has joined.\"
  respond client \"Welcome!\"
@

When a connection is received, a new 'ClientConn' is created and added to
the servers 'clientList'. At this point, the 'ConnectionHandler' is notified
and a message is 'broadcast'ed to all connected clients. After this occurs,
the server `respond`s to the new client.

To create a 'DisconnectHandler' that notifies all clients that a user has
disconnected and send a goodbye message to the disconnecting client, one
might define the following:

@
simpleDisconnect :: DisconnectHandler
simpleDisconnect server client = do
  broadcast server \"A user has left the room.\"
  respond client \"Goodbye!\"
@

When a user disconnects, the server will call the 'DisconnectHandler' so any
cleanup may be done.

To create a 'CmdHandler' that repeats a received message to all connected
clients, one might define the following:

@
repeatHandler :: CmdHandler
repeatHandler (cmd:msg) server client = do
  name <- lookup client \"name\"
  broadcast server $ name ++ "> " ++ (unwords msg)
@

The message 'CmdHandler' is passed a list of strings which is the 
message received from the client. 
The first element of the list is the \"command\" that triggered the callback.
-}

{- $server
To start using a simple server, one simply specifies the 'ConnectionHandler', 'DisconnectHandler', and port that the server will use.

> server <- new simpleConnect simpleDisconnect 10010

The server does not start after construction, instead one may now register
any number of 'CmdHandler's on the server using 'addCommand'.

> addCommand server "/repeat" repeatHandler

Once all of the desired 'CmdHandler's have been registered on the server
the server may be started using 'start' 

> start server

If the port specified for the server is available, a new thread is started
and the server will now accept incoming connections. The control will then be returned to the thread that called 'start'. 

The incomming connections will be handed off to the 
specified 'ConnectionHandler' and incoming messages
will be handed to the appropriate 'CmdHandler'. If an incoming message has
no 'CmdHandler' the message \"Invalid command: <cmd>\" will be sent to the
client. If a client does not communicate with the server for more than 60 seconds
the client is disconnected from the server.

To stop a server use 'stop'

> stop server

All client buffers are flushed and disconnected from the server. All threads and
handles that have been created by the server are killed and closed and then the
control is returned to the thread that called stop.

-}

{- $client

Each time a connection is made to a server a new 'ClientConn' is created and
added to the servers 'clientList'. The server then invokes a call to its
'ConnectionHandler'.

Each 'ClientConn' has a unique 'cid' and property table which can be accessed 
with 'lookup' and modified with 'modify'. Each stored property is defined
by a String and stores an associated String. If a property has never been
set using 'modify' it will be the empty string on 'lookup'.

If you wanted to write a 'CmdHandler' that allowed a user to specify the
value stored in their table called \"name\", one might define:

@
nameHandler :: CmdHandler
nameHandler (_:msg) server client = do
  case msg of
    [] -> respond client \"You did not provide a name to change to.\"
    msg -> do
      before <- lookup client \"name\"
      let name = unwords msg
          message = before ++ \" is now known as \" ++ name
      modify client \"name\" name
      broadcast server message
@

This 'CmdHandler' first checks that the client specified a name that
was not entirely white space. Then, it generates a message stating the name
they were using and the name they are now using with 'lookup'. Then using
'modify' the clients property \"name\"is changed to the value specified.
Finally, the generated message is 'broadcast' to all connected clients.

-}