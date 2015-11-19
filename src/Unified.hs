module Unified where

import Diff
import Patch
import Syntax
import Term
import Control.Monad.Free

unified :: Diff a annotation -> String -> String -> String
unified diff before after =
  iter f mapped where
    mapped = fmap unifiedPatch diff
    f (Annotated annotations (Leaf _)) = ""
    f (Annotated annotations (Indexed i)) = ""
    f (Annotated annotations (Fixed f)) = ""
    f (Annotated annotations (Keyed k)) = ""
    unifiedPatch :: Patch (Term a annotation) -> String
    unifiedPatch _ = ""

substring :: Range -> String -> String
substring range = take (end range) . drop (start range)
