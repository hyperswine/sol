{-# LANGUAGE NoRebindableSyntax #-}
{-# OPTIONS_GHC -fno-warn-missing-import-lists #-}
{-# OPTIONS_GHC -w #-}
module PackageInfo_sol (
    name,
    version,
    synopsis,
    copyright,
    homepage,
  ) where

import Data.Version (Version(..))
import Prelude

name :: String
name = "sol"
version :: Version
version = Version [0,1,0,0] []

synopsis :: String
synopsis = "Sol \8212 the portable VM edition of FPRISC (PoC)"
copyright :: String
copyright = ""
homepage :: String
homepage = ""
