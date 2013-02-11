module Network.SimpleServer.Examples.ChatClient(main) where
import Network
import System.Environment
import Control.Concurrent
import Control.Concurrent.MVar
import Control.Concurrent.Thread.Delay
import Control.Monad
import System.IO
import Data.Char

-- Attempts to connect to a host on a specified port
-- If successful, a thread is started that prints out
-- incoming data, a thread starts that takes input from
-- standard in, and a thread starts that pings the server
-- every 30 seconds. Once the message "disconnect" is received
-- from the server, each thread stops and the program exits.
run :: HostName -> Int -> IO ()
run host port = do
  handle <- connectTo host (PortNumber (fromIntegral port))
  stopVar <- newEmptyMVar
  ioo <- forkIO $ forever (doOutput handle)
  ioi <- forkIO $ forever (doInput handle stopVar)
  iom <- forkIO $ forever (maintainConnection handle)
  readMVar stopVar
  killThread ioo
  killThread ioi
  killThread iom
  return ()
  
-- Given a handle, takes a line from standard in and
-- sends it to the handle. If the message starts with a '/'
-- it is sent normally, if it does not start with '/' a
-- '/message ' is appended to the front of it before it is
-- sent.
doOutput :: Handle -> IO ()
doOutput handle = do
  msg <- getLine
  case msg of
    msg@('/':_) -> hPutStrLn handle msg
    msg -> hPutStrLn handle $ "/message " ++ msg

-- Given a handle for sending output, reads a line and
-- prints it to stdout. If the input is "disconnected"
-- the mvar is set which allows the main thread to die.
doInput :: Handle -> MVar Bool -> IO ()
doInput handle mvar = do
  string <- hGetLine handle
  putStrLn string
  if string == "disconnected" then putMVar mvar True else return ()

-- Sends the '/ping silent' command to the server
-- every 30 seconds
maintainConnection :: Handle -> IO ()
maintainConnection handle = do
  hPutStrLn handle "/ping silent"
  delay (1000 * 1000 * 30) -- 30 seconds

main = do
  args <- getArgs
  case args of
    [] -> printUsage
    (x:[]) -> printUsage
    (host:port:_) -> if isInt port then run host (read port) else printUsage
                                                   
printUsage :: IO ()                                                   
printUsage = putStrLn "./ChatClient hostname port"

isInt :: [Char] -> Bool
isInt = (== []) . (filter (not . isDigit))