{-# LANGUAGE DeriveGeneric, InterruptibleFFI, RankNTypes, RecordWildCards #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}

module TreeSitter.CursorApi.Cursor (
  Cursor(..),
  SpanInfo(..)
  , tsTransformSpanInfos
  , tsTransformZipper
  , tsTransformIdentityZipper
  , ts_cursor_init  
  , ts_cursor_goto_first_child
  , ts_cursor_goto_next_sibling
  , ts_cursor_goto_parent
  , funptr_ts_cursor_free
) where

import Foreign
import Foreign.Ptr
import Foreign.C
import Foreign.C.Types
import Foreign.Marshal.Utils
import GHC.Generics

import TreeSitter.Tree
import TreeSitter.Struct
import TreeSitter.CursorApi.Types

import qualified Data.Tree as T
import qualified Data.Tree.Zipper as Z
import Data.Maybe
import Control.Monad.Identity

import Data.Loc.Span hiding ((+))
import Data.Loc.Loc
import Data.Loc.Pos


data Cursor = Cursor
  { nodeType :: !CString
  , nodeStr :: !CString
  , nodeSymbol :: !Word16
  , nodeStartPoint :: !TSPoint
  , nodeEndPoint :: !TSPoint
  , nodeStartByte :: !Word32
  , nodeEndByte :: !Word32
  }
  deriving (Show, Eq, Generic)

type PtrCur = Ptr Cursor

data TSPoint = TSPoint { pointRow :: !Word32, pointColumn :: !Word32 }
  deriving (Show, Eq, Generic)

instance Storable Cursor where
  alignment _ = alignment (nullPtr :: Ptr ())
  sizeOf _ = 36
  peek = evalStruct $ Cursor <$> peekStruct
                             <*> peekStruct
                             <*> peekStruct
                             <*> peekStruct
                             <*> peekStruct
                             <*> peekStruct
                             <*> peekStruct
  poke _ _ = error "Cant poke"

instance Storable TSPoint where
  alignment _ = alignment (0 :: Int32)
  sizeOf _ = 8
  peek = evalStruct $ TSPoint <$> peekStruct
                              <*> peekStruct
  poke _ _ = error "Cant poke"


data Navigation = Down | Next | Up

data CursorOperations a m c = CursorOperations 
                      { initResult     :: Monad m => a -> m c
                      , packNode       :: Monad m => a -> Navigation -> c -> m c
                      , nodeFirstChild :: Monad m => (a -> m (Maybe a))
                      , nodeNext       :: Monad m => (a -> m (Maybe a))
                      , nodeParent     :: Monad m => (a -> m (Maybe a))
                      }


locspan :: Ptr Cursor -> IO Span
locspan cur = do
  Cursor{..} <- peek cur
  let startLoc = loc (saveLine nodeStartPoint) (saveColumn nodeStartPoint)
      endLoc = loc (saveLine nodeEndPoint) (saveColumn nodeEndPoint)
    in return $ fromTo startLoc endLoc

saveLine :: TSPoint -> Line
saveLine TSPoint{..} = fromInteger $ toInteger (pointRow + 1)

saveColumn :: TSPoint -> Column
saveColumn TSPoint{..} = fromInteger $ toInteger (pointColumn + 1)

spanInfoFromCursor :: Ptr Cursor -> IO SpanInfo
spanInfoFromCursor ptrCur = do
  span <- locspan ptrCur
  isParent <- hasChildren
  return (if isParent then Parent span else Token span)

-- transformations

tsTransformSpanInfos :: PtrCur -> IO [SpanInfo]
tsTransformSpanInfos = tsTransform curopsList

packNodeList :: PtrCur -> Navigation -> [SpanInfo] -> IO [SpanInfo]
packNodeList ptrCur _ spanInfos = do
  spanInfo <- spanInfoFromCursor ptrCur
  return $ spanInfo : spanInfos

initList :: PtrCur -> IO [SpanInfo]
initList ptrCur = do
  spanInfo <- spanInfoFromCursor ptrCur
  return [spanInfo]

curopsList :: CursorOperations PtrCur IO [SpanInfo]
curopsList = CursorOperations
            { initResult     = initList
            , packNode       = packNodeList
            , nodeFirstChild = firstChild
            , nodeNext       = next
            , nodeParent     = parent
            }


tsTransformZipper :: PtrCur -> IO (Z.TreePos Z.Full String)
tsTransformZipper = tsTransform curopsZipper

packNodeZipper :: PtrCur -> Navigation -> Z.TreePos Z.Full String -> IO (Z.TreePos Z.Full String)
packNodeZipper ptrCur nav resultZipper =
  case nav of
      Down -> do
        l <- label ptrCur
        return $ insertNode l (Z.children resultZipper)

      Next -> do
        l <- label ptrCur
        return $ insertNode l (Z.nextSpace resultZipper)

      Up -> return (fromJust $ Z.parent resultZipper)

  where
    insertNode lbl = Z.insert (T.Node lbl [])

initZipper :: PtrCur -> IO (Z.TreePos Z.Full String)
initZipper ptrCur = do
  rootLabel <- label ptrCur
  return $ Z.fromTree (T.Node rootLabel [])

curopsZipper :: CursorOperations (Ptr Cursor) IO (Z.TreePos Z.Full String)
curopsZipper = CursorOperations
            { initResult     = initZipper
            , packNode       = packNodeZipper
            , nodeFirstChild = firstChild
            , nodeNext       = next
            , nodeParent     = parent
            }


tsTransformIdentityZipper :: Z.TreePos Z.Full String -> Identity (Z.TreePos Z.Full String)
tsTransformIdentityZipper = tsTransform curopsIdentityZipper

packNodeIdentityZipper :: Z.TreePos Z.Full String -> Navigation -> Z.TreePos Z.Full String -> Identity (Z.TreePos Z.Full String)
packNodeIdentityZipper ptrCur nav resultZipper =
  case nav of
    Down -> return $ insertNode (Z.label ptrCur) (Z.children resultZipper)
    Next -> return $ insertNode (Z.label ptrCur) (Z.nextSpace resultZipper)
    Up -> return (fromJust $ Z.parent resultZipper)
  where
    insertNode lbl = Z.insert (T.Node lbl [])

initIdentityZipper :: Z.TreePos Z.Full String -> Identity (Z.TreePos Z.Full String)
initIdentityZipper ptrCur = return $ Z.fromTree (T.Node (Z.label ptrCur) [])

curopsIdentityZipper :: CursorOperations (Z.TreePos Z.Full String) Identity (Z.TreePos Z.Full String)
curopsIdentityZipper = CursorOperations
            { initResult     = initIdentityZipper
            , packNode       = packNodeIdentityZipper
            , nodeFirstChild = return . Z.firstChild
            , nodeNext       = return . Z.next
            , nodeParent     = return . Z.parent
            }


tsTransform :: Monad m => CursorOperations a m c -> a -> m c
tsTransform curops@CursorOperations{..} ptrCur = do
  res <- initResult ptrCur
  go curops res Down ptrCur
  where
    go :: Monad m => CursorOperations a m c -> c -> Navigation -> a -> m c
    go curops@CursorOperations{..} res nav ptrCur = case nav of
      Down -> do
        fc <- nodeFirstChild ptrCur
        case fc of
          Nothing      -> go curops res Next ptrCur
          Just ptrCur' -> do
            res' <- packNode ptrCur' Down res
            go curops res' Down ptrCur'
      
      Next -> do
        n <- nodeNext ptrCur
        case n of
          Nothing      -> go curops res Up ptrCur
          Just ptrCur' -> do
            res' <- packNode ptrCur' Next res
            go curops res' Down ptrCur'

      Up -> do
        p <- nodeParent ptrCur
        case p of
          Nothing      -> return res
          Just ptrCur' -> do
            r <- packNode ptrCur' Up res
            go curops r Next ptrCur'



label :: Ptr Cursor -> IO String
label cur = do
  node <- peek cur
  nodeType <- peekCString (nodeType node)
  let nodeStart = nodeStartPoint node
      nodeEnd   = nodeEndPoint node
      startPoint = show (pointRow nodeStart, pointColumn nodeStart)
      endPoint = show (pointRow nodeEnd, pointColumn nodeEnd)
    in      
    return $ nodeType ++ " " ++ startPoint ++ "-" ++ endPoint

firstChild :: Ptr Cursor -> IO (Maybe (Ptr Cursor))
firstChild cur = do
  exists <- ts_cursor_goto_first_child cur
  return $ boolToMaybe cur exists

next :: Ptr Cursor -> IO (Maybe (Ptr Cursor))
next cur = do
  exists <- ts_cursor_goto_next_sibling cur
  return $ boolToMaybe cur exists

parent :: Ptr Cursor -> IO (Maybe (Ptr Cursor))
parent cur = do
  exists <- ts_cursor_goto_parent cur
  return $ boolToMaybe cur exists

hasChildren :: IO Bool
hasChildren = toBool <$> ts_cursor_has_children

boolToMaybe :: Ptr Cursor -> CBool  -> Maybe (Ptr Cursor)
boolToMaybe cur exists =
  if exists == 1
    then Just cur
    else Nothing



foreign import ccall ts_cursor_init :: Ptr Tree -> Ptr Cursor -> IO ()
foreign import ccall ts_cursor_goto_first_child :: Ptr Cursor -> IO CBool
foreign import ccall ts_cursor_goto_next_sibling :: Ptr Cursor -> IO CBool
foreign import ccall ts_cursor_goto_parent :: Ptr Cursor -> IO CBool
foreign import ccall ts_cursor_has_children :: IO CBool
foreign import ccall "&ts_cursor_free" funptr_ts_cursor_free :: FunPtr (Ptr Cursor -> IO ())
