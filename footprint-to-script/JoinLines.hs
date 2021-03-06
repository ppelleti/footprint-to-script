{-# LANGUAGE MultiWayIf #-}

module JoinLines
  ( V2Sci
  , dbl2sci
  , vdbl2sci
  , MyItem(..)
  , convertLines
  , joinLines
  ) where

import Control.Monad.Trans.State.Strict
import Data.Kicad.PcbnewExpr.PcbnewExpr
import Data.List
import qualified Data.Map.Strict as M
import Data.Ord
import Data.Scientific

type V2Sci = (Scientific, Scientific)

dbl2sci :: Double -> Scientific
dbl2sci = read . show

vdbl2sci :: V2Double -> V2Sci
vdbl2sci (x, y) = (dbl2sci x, dbl2sci y)

data MyItem = Other
              { iSeq :: Int
              , iOther :: PcbnewItem
              }
            | Rectangle
              { iSeq :: Int
              , iCorner1 :: V2Sci
              , iCorner2 :: V2Sci
              , iLayer :: PcbnewLayerT
              , iWidth :: Scientific
              }
            | Polyline
              { iSeq :: Int
              , iPoints :: [V2Sci]
              , iLayer :: PcbnewLayerT
              , iWidth :: Scientific
              }
            deriving (Eq, Show)

convertLines :: [PcbnewItem] -> [MyItem]
convertLines items = zipWith cvt items [0..]
  where cvt item@(PcbnewFpLine {}) n =
          Polyline
          { iSeq = n
          , iPoints = map vdbl2sci [itemStart item, itemEnd item]
          , iLayer = itemLayer item
          , iWidth = dbl2sci (itemWidth item)
          }
        cvt item n =
          Other
          { iSeq = n
          , iOther = item
          }

isPolyline :: MyItem -> Bool
isPolyline (Polyline {}) = True
isPolyline _ = False

joinLines :: [MyItem] -> [MyItem]
joinLines items = sortBy (comparing iSeq) (others ++ ls')
  where (ls, others) = partition isPolyline items
        ls' = map (identifyRect . eliminateRedundantVertices) $ joinLines1 ls

-- Input must be Polyline.  Output is Polyline or Rectangle.
identifyRect :: MyItem -> MyItem
identifyRect item@(Polyline { iPoints = [ p1@(x1, y1)
                                        , (x2, y2)
                                        , p3@(x3, y3)
                                        , (x4, y4)
                                        , p5 ] })
  | p1 == p5 && x1 /= x3 && y1 /= y3 &&
    sort [x1, x2, x3, x4] == sort [x1, x1, x3, x3] &&
    sort [y1, y2, y3, y4] == sort [y1, y1, y3, y3] =
    Rectangle
    { iSeq = iSeq item
    , iCorner1 = p1
    , iCorner2 = p3
    , iLayer = iLayer item
    , iWidth = iWidth item
    }
  | otherwise = item
identifyRect item = item

-- Input and output are Polylines.
eliminateRedundantVertices :: MyItem -> MyItem
eliminateRedundantVertices item = item { iPoints = erv (iPoints item) }
  where erv (p1:p2:p3:rest) =
          if colinear p1 p2 p3
          then erv (p1:p3:rest)
          else p1 : erv (p2:p3:rest)
        erv pts = pts

colinear :: V2Sci -> V2Sci -> V2Sci -> Bool
colinear p1@(x1, y1) p2@(x2, y2) p3@(x3, y3) =
  colin p1 p2 p3 || colin (y1, x1) (y2, x2) (y3, x3)

colin :: V2Sci -> V2Sci -> V2Sci -> Bool
colin (x1, y1) (x2, y2) (x3, y3) =
  x1 == x2 && x2 == x3 && ((y1 <= y2 && y2 <= y3) || (y1 >= y2 && y2 >= y3))

type ItemMap = M.Map V2Sci [MyItem]

-- The inputs and outputs of this function are all Polylines,
-- although Haskell's type system doesn't have a way to
-- express that.
joinLines1 :: [MyItem] -> [MyItem]
joinLines1 = concatMap joinLines' . groupBy grp . sortBy (comparing f)
  where grp i1 i2 = f i1 == f i2
        f item = (layerToStr (iLayer item), iWidth item)

-- These MyItems are all Polylines.
-- This function assumes all the Polylines have the same width
-- and layer.
joinLines' :: [MyItem] -> [MyItem]
joinLines' = flattenItemMap . processItemMap . makeItemMap

-- These MyItems are all Polylines
makeItemMap :: [MyItem] -> ItemMap
makeItemMap items = execState go M.empty
  where go = mapM_ f items
        f item = do
          addItem (head $ iPoints item) item
          addItem (last $ iPoints item) item

-- These MyItems are all Polylines
processItemMap :: ItemMap -> ItemMap
processItemMap m = execState go m
  where go = mapM_ processPoint (M.keys m)

-- These MyItems are all Polylines
flattenItemMap :: ItemMap -> [MyItem]
flattenItemMap m = M.elems $ foldr f M.empty $ concat $ M.elems m
  where f item m' = M.insert (iSeq item) item m'

type IState = State ItemMap

addItem' :: ItemMap -> V2Sci -> MyItem -> ItemMap
addItem' m key item = M.insertWith combine key [item] m
  where combine a b = nub $ a ++ b

removeItem' :: ItemMap -> V2Sci -> MyItem -> ItemMap
removeItem' m key item = M.update upd key m
  where upd items = maybeNothing $ delete item items
        maybeNothing [] = Nothing
        maybeNothing xs = Just xs

getPoint :: V2Sci -> IState [MyItem]
getPoint pt = do
  m <- get
  return $ M.findWithDefault [] pt m

addItem :: V2Sci -> MyItem -> IState ()
addItem key item = do
  m <- get
  let m' = addItem' m key item
  put m'

removeItem :: V2Sci -> MyItem -> IState ()
removeItem key item = do
  m <- get
  let m' = removeItem' m key item
  put m'

processPoint :: V2Sci -> IState ()
processPoint pt = do
  items <- getPoint pt
  processItems items pt

processItems :: [MyItem] -> V2Sci -> IState ()
processItems [] _ = return ()
processItems [_] _ = return ()
processItems (i1:i2:rest) pt = joinItems i1 i2 pt >> processItems rest pt

joinItems :: MyItem -> MyItem -> V2Sci -> IState ()
joinItems i1 i2 pt = do
  removeBothEnds i1
  removeBothEnds i2
  let i3 = combineLines i1 i2 pt
  addBothEnds i3

removeBothEnds :: MyItem -> IState ()
removeBothEnds item = do
  let pts = iPoints item
      pt1 = head pts
      pt2 = last pts
  removeItem pt1 item
  removeItem pt2 item

addBothEnds :: MyItem -> IState ()
addBothEnds item = do
  let pts = iPoints item
      pt1 = head pts
      pt2 = last pts
  addItem pt1 item
  addItem pt2 item

combineLines :: MyItem -> MyItem -> V2Sci -> MyItem
combineLines i1 i2 pt =
  let pts1 = iPoints i1
      pts2 = iPoints i2
      pt1a = head pts1
      pt1b = last pts1
      pt2a = head pts2
      pt2b = last pts2
      (pts1', pts2') =
        if | pt1a == pt && pt2a == pt -> (reverse pts1, pts2)
           | pt1a == pt && pt2b == pt -> (pts2, pts1)
           | pt1b == pt && pt2a == pt -> (pts1, pts2)
           | pt1b == pt && pt2b == pt -> (pts1, reverse pts2)
      pts' = pts1' ++ tail pts2'
  in Polyline
     { iSeq = min (iSeq i1) (iSeq i2)
     , iPoints = pts'
     , iLayer = iLayer i1
     , iWidth = iWidth i1
     }
