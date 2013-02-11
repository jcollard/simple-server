module Network.SimpleServer.Examples.ChatServer(main) where
import Data.Char
import Data.List
import System.Environment

import qualified Network.SimpleServer as S

-- Constants --
-- A Welcome message to send to clients when they connect.
welcomeMessage = "Welcome to the Simple Chat Server.\n" ++
                 "Commands:\n" ++
                 "/message [message] - Broadcast a message to all users.\n" ++
                 "/name [newname] - Change your name to newname.\n" ++
                 "/ping - Let's the server know you're still there.\n" ++ 
                 "/who - Displays a list of users connected to the server.\n" ++
                 "/disconnect - Disconnect from Simple Chat Server.\n"

-- Keys
-- The display name for a ClientConn
username = "username"

-- Handlers

-- The Connection Handler sets a newly connected
-- users username to "user #{cid}" broadcasts
-- that they have connected and then sends them the welcome message
connHandler :: S.ConnectionHandler
connHandler server client = do
  let name = "user #" ++ (show (S.cid client))
      msg = name ++ " connected."
  S.modify client username name
  S.broadcast server msg
  S.respond client welcomeMessage

-- The Disconnection Handler responds to the client "disconnected"
-- Then broadcasts to the room that the user has disconnected
dissHandler :: S.DisconnectHandler
dissHandler server client = do
  name <- S.lookup client username
  let msg = name ++ " disconnected."
  S.respond client "disconnected"
  S.broadcast server msg

-- Commands
  
-- The name command sets the username to the value specified
-- by the user as long as it is not the empty string. If
-- the name is the empty string, the client is notified that
-- the name is not valid. Otherwise, a message is broadcast
-- stating the user changed their name
nameCmd = "/name"
nameHandler :: S.CmdHandler
nameHandler (_:msg) server client = do
  case msg of
    [] -> S.respond client "You did not provide a name to change to."
    msg -> do
      before <- S.lookup client username
      let name = intercalate " " msg
          message = before ++ " is now known as " ++ name
      S.modify client username (intercalate " " msg)
      S.broadcast server message

-- The ping command notifies the server that the user is still connected
-- so they don't time out. If the /ping command is followed by "silent"
-- the server does not respond. Otherwise, the server responds with
-- a received message.
pingCmd = "/ping"
pingHandler :: S.CmdHandler
pingHandler (_:flag) _ client = do
  case flag of
    ("silent":_) -> return ()
    _ -> S.respond client "Ping received."

-- If the message command is received, any text following it is
-- broadcast to all users.
msgCmd = "/message"
msgHandler :: S.CmdHandler
msgHandler (cmd:msg) server client = do
  name <- S.lookup client username
  S.broadcast server $ name ++ "> " ++ (intercalate " " msg)

-- The disconnect command causes the message "Goodbye!" to be sent to
-- the client. Then they are disconnected from the server.
disCmd = "/disconnect"
disHandler :: S.CmdHandler
disHandler _ server client = do
  S.respond client "Goodbye!"
  S.disconnectClient server client
  
-- The who command responds to the client with
-- a list of usernames
whoCmd = "/who"
whoHandler :: S.CmdHandler
whoHandler _ server client = do
  clients <- S.clientList server
  usernames <- mapM (flip S.lookup username) clients
  let message = "Users:\n" ++ (intercalate "\n" usernames)
  S.respond client message

-- Builds a server on the given port, adds the commands
-- starts the server, and waits for the word stop to be entered
run :: Int -> IO ()
run port = do
  server <- S.new connHandler dissHandler port
  S.addCommand server whoCmd whoHandler
  S.addCommand server nameCmd nameHandler
  S.addCommand server disCmd disHandler
  S.addCommand server msgCmd msgHandler
  S.addCommand server pingCmd pingHandler
  S.start server
  putStrLn $ "Chat Server Started on Port: " ++ (show port)
  putStrLn $ "Type 'stop' to stop the server."
  waitStop server
  putStrLn "Server Stopped"

-- Waits for the word 'stop' to be entered
waitStop :: S.Server -> IO ()
waitStop server = do
  string <- getLine
  if string == "stop" then S.stop server else waitStop server
  
-- Starts a server on the specified port or prints the usage message
main = do
  args <- getArgs
  case args of
    [] -> printUsage
    (x:_) -> if isInt x then (return (read x)) >>= run else printUsage

printUsage :: IO ()
printUsage = putStrLn "Usage ./ChatServer [port]"

isInt :: [Char] -> Bool
isInt = (== []) . (filter (not . isDigit))