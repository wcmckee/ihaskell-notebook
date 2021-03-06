module Evaluation where

import Bag (foldrBag, lengthBag)
import Control.Monad.State
import System.IO (IOMode(..), stdout, stderr, openFile, hClose, writeFile)
import qualified System.IO.Strict as IOS (readFile)
import System.IO.Silently (hCapture)
import System.Environment (getEnvironment)
import Data.List (intercalate)

import Exception (ExceptionMonad)
import GHC
import GhcMonad
import GHC.Paths
import DynFlags
import HscTypes
import StringBuffer
import Data.Time.Clock
import Outputable
-- import Finder
import MonadUtils (liftIO)
import InteractiveEval (RunResult(..))

import Types

runtimeSrcDir :: FilePath
runtimeSrcDir = "runtimesrc"

-- | TODO not cross-platform
mkPath :: [String] -> FilePath
mkPath xs = intercalate "/" xs

mkTargetMod :: FilePath -> String -> String -> IO (ModuleName, Target)
mkTargetMod tmpDir name code = do 
  let fName = mkPath [tmpDir, name ++ ".hs"]
  writeFile fName "-- ghc needs a file to exist with this name."
  now <- getCurrentTime
  let modName = mkModuleName name
  return ( modName
         , Target { targetId = TargetModule modName
                  , targetAllowObjCode = False
                  , targetContents = Just (stringToStringBuffer code, now)
                  })

mkTargetFile :: FilePath -> IO Target
mkTargetFile path = do return Target { targetId = TargetFile path Nothing
                                     , targetAllowObjCode = False
                                     , targetContents = Nothing
                                     }

mkCustomPrelude :: FilePath -> FilePath -> IO (ModuleName, Target)
mkCustomPrelude tmpFile tmpDir = mkTargetMod tmpDir "OurPrelude" ourPreludeSrc
    where ourPreludeSrc = "module OurPrelude where\n"++
                          "import Prelude\n" ++
                          "temp_file = "++show tmpFile

customPrintFnStr :: String
customPrintFnStr = "Printer.ourPrint"

mkModules :: FilePath -> FilePath -> IO [(ModuleName, Target)]
mkModules tmpFile tmpDir = do
  env <- getEnvironment
  let ghcjDir = case lookup "IHNB_ROOT" env of
                  Nothing   -> "."
                  Just path -> mkPath [path, "ghcj"]
  (preludeName, ourPrelude) <- mkCustomPrelude tmpFile tmpDir
  printer                   <- mkTargetFile (mkPath [ghcjDir, runtimeSrcDir, "Printer.hs"])
  let printerName = mkModuleName "Printer"
  return [ (preludeName, ourPrelude)
         , (printerName, printer)]

initSession :: FilePath -> FilePath -> IO Session
initSession tmpFile tmpDir = runGhc (Just libdir) $ do
                dflags <- getSessionDynFlags
                setSessionDynFlags dflags { ghcLink = LinkInMemory
                                          , hscTarget = HscInterpreted
                                          , importPaths = tmpDir:runtimeSrcDir:(importPaths dflags)
                                          -- | Interactive print
                                          -- doesn't seem to work, but
                                          -- parseName (below) does
                                          , interactivePrint = Just customPrintFnStr }

                modules <- MonadUtils.liftIO $ mkModules tmpFile tmpDir
                mapM_ (addTarget . snd) modules

                sFlag <- load LoadAllTargets
                case sFlag of
                     Failed    -> error "Could not initialize session."
                     Succeeded -> do
                                setContext $ map (IIModule . fst)  modules
                                -- setContext [ IIModule $ mkModuleName "OurPrelude"
                                --            , IIModule $ mkModuleName "Printer"]

                                (name:_) <- parseName customPrintFnStr
                                modifySession (\he -> let new_ic = setInteractivePrintName (hsc_IC he) name
                                                      in he { hsc_IC = new_ic })

                                -- reifyGhc takes a function of (Session -> IO a) and
                                -- returns Ghc a.  we use it here to get and return
                                -- the Session:
                                reifyGhc return

evalModule :: Int -> String -> StateT EvalState Ghc Output
evalModule cId code = do 
  let moduleName = ("Module"++show cId)
      fullModule = "module "++moduleName++" where\n\n"++code
  tmpDir <- gets estateTmpDir
  
  -- do a bunch of work in the ghc monad:
  lift $ do (mName, target) <- MonadUtils.liftIO $ mkTargetMod tmpDir moduleName fullModule
            removeTarget $ targetId target
            addTarget target

            -- MonadUtils.liftIO $ print "About to load"
            handleSourceError srcErrorHdlr $
             do (str, sFlag) <- wrappedLoadAll
                case sFlag of
                  Failed    -> return $ CompileError ("Error loading module:\n"++str)
                  Succeeded -> do setContext [ IIModule mName
                                             -- add the base modules:
                                             , IIModule $ mkModuleName "OurPrelude"
                                             , IIModule $ mkModuleName "Printer"]

                                  -- names <- getNamesInScope
                                  -- MonadUtils.liftIO $ putStrLn "names---"
                                  -- MonadUtils.liftIO $ mapM_ (printOut flags) names
                                  -- MonadUtils.liftIO $ putStrLn "---end names"

                                  (name:_) <- parseName customPrintFnStr
                                  modifySession (\he -> let new_ic = setInteractivePrintName (hsc_IC he) name
                                                        in he { hsc_IC = new_ic })

                                  return Output { outputCellNo = cId
                                                , outputData = "(module parsed: "++str++")"
                                                , outputMimeType = "text/plain"
                                                }

wrappedLoadAll :: Ghc (String, SuccessFlag)
wrappedLoadAll = reifyGhc (\s -> hCapture [stdout, stderr] (reflectGhc (load LoadAllTargets) s))
                   
srcErrorHdlr :: ExceptionMonad m => SourceError -> m Output
srcErrorHdlr srcErr = return $ CompileError ("srcErrorHdlr" ++ (showErrThing $ srcErrorMessages srcErr))

showErrThing err = foldrBag (\a r -> r ++ (show a)) "" err



evalStmt :: Int -> String -> StateT EvalState Ghc Output
evalStmt cId stmt = do runResult <- lift $ gcatch (runStmt stmt RunToCompletion) errHandler
                       case runResult of
                         RunBreak {}      -> return $ CompileError "RunBreak"
                         (RunException e) -> return (CompileError $ show e)
                         (RunOk _)        -> do tmpFile <- gets estateTmpFile
                                                (mimeType, itVal) <- lift $ MonadUtils.liftIO $ getItVal tmpFile
                                                return Output { outputCellNo = cId
                                                              , outputData = itVal 
                                                              , outputMimeType = mimeType }
    where errHandler e = return $ RunException e

-- | Get the value of 'it' from the temp file.
getItVal :: FilePath -> IO (String, String)
getItVal path = do val <- IOS.readFile path
                   clearTmpFile path
                   let (mimeType:result) = lines val
                   return (mimeType, unlines result)

-- | TODO put some exception handling in here (just in case)
clearTmpFile :: FilePath -> IO ()
clearTmpFile file = do hdl <- openFile file WriteMode
                       hClose hdl

runResultToStr :: RunResult -> String
runResultToStr (RunOk ns)      = "RunOk " ++ (show $ length ns)
runResultToStr (RunException e) = "RunException " ++ show e
runResultToStr RunBreak {}     = "RunBreak"

showOut flags name = let ctx = initSDocContext flags defaultDumpStyle
                     in runSDoc (ppr name) ctx
printOut flags name = print $ showOut flags name
