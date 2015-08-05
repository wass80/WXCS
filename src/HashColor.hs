module HashColor (
  hueColor,
  cssColor
  ) where

import Data.Hashable

maxHue :: Int
maxHue 65536

hueColor :: String -> Int
hueColor = mod maxHue . hash

cssColor :: String -> String
cssColor = "hsl(" ++ (hueColor) * 360 `div` maxHue ++ ",100%,50%)"

