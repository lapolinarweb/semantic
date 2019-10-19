{-# LANGUAGE ConstraintKinds, GeneralizedNewtypeDeriving, MonoLocalBinds, RankNTypes, StandaloneDeriving #-}
module Semantic.Api.Terms
  ( termGraph
  , parseTermBuilder
  , TermOutputFormat(..)
  ) where

import           Analysis.ConstructorName (ConstructorName)
import           Control.Effect.Error
import           Control.Effect.Parse
import           Control.Effect.Reader
import           Control.Lens
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Blob
import           Data.ByteString.Builder
import           Data.Either
import           Data.Graph
import           Data.JSON.Fields
import           Data.Language
import           Data.ProtoLens (defMessage)
import           Data.Quieterm
import           Data.Term
import qualified Data.Text as T
import           Parsing.Parser
import           Prologue
import           Proto.Semantic as P hiding (Blob)
import           Proto.Semantic_Fields as P
import           Proto.Semantic_JSON()
import           Rendering.Graph
import           Rendering.JSON hiding (JSON)
import qualified Rendering.JSON
import           Semantic.Api.Bridge
import           Semantic.Config
import           Semantic.Task
import           Serializing.Format hiding (JSON)
import qualified Serializing.Format as Format
import qualified Serializing.SExpression as SExpr (serializeSExpression)
import qualified Serializing.SExpression.Precise as SExpr.Precise (serializeSExpression)
import           Source.Loc

import qualified Language.Java as Java
import qualified Language.JSON as JSON
import qualified Language.Go.Term as Go
import qualified Language.Markdown.Term as Markdown
import qualified Language.PHP.Term as PHP
import qualified Language.Python as PythonPrecise
import qualified Language.Python.Term as PythonALaCarte
import qualified Language.Ruby.Term as Ruby
import qualified Language.TSX.Term as TSX
import qualified Language.TypeScript.Term as TypeScript


termGraph :: (Traversable t, Member Distribute sig, ParseEffects sig m) => t Blob -> m ParseTreeGraphResponse
termGraph blobs = do
  terms <- distributeFor blobs go
  pure $ defMessage
    & P.files .~ toList terms
  where
    go :: ParseEffects sig m => Blob -> m ParseTreeFileGraph
    go blob = parseWith jsonGraphTermParsers (pure . jsonGraphTerm blob) blob
      `catchError` \(SomeException e) ->
        pure $ defMessage
          & P.path .~ path
          & P.language .~ lang
          & P.vertices .~ mempty
          & P.edges .~ mempty
          & P.errors .~ [defMessage & P.error .~ T.pack (show e)]
      where
        path = T.pack $ blobPath blob
        lang = bridging # blobLanguage blob

data TermOutputFormat
  = TermJSONTree
  | TermJSONGraph
  | TermSExpression
  | TermDotGraph
  | TermShow
  | TermQuiet
  deriving (Eq, Show)

parseTermBuilder :: (Traversable t, Member Distribute sig, ParseEffects sig m, MonadIO m)
  => TermOutputFormat -> t Blob -> m Builder
parseTermBuilder TermJSONTree    = distributeFoldMap jsonTerm >=> serialize Format.JSON -- NB: Serialize happens at the top level for these two JSON formats to collect results of multiple blobs.
parseTermBuilder TermJSONGraph   = termGraph >=> serialize Format.JSON
parseTermBuilder TermSExpression = distributeFoldMap (\ blob -> asks sexprTermParsers >>= \ parsers -> parseWith parsers (pure . sexprTerm) blob)
parseTermBuilder TermDotGraph    = distributeFoldMap (parseWith dotGraphTermParsers dotGraphTerm)
parseTermBuilder TermShow        = distributeFoldMap (\ blob -> asks showTermParsers >>= \ parsers -> parseWith parsers showTerm blob)
parseTermBuilder TermQuiet       = distributeFoldMap quietTerm

jsonTerm :: ParseEffects sig m => Blob -> m (Rendering.JSON.JSON "trees" SomeJSON)
jsonTerm blob = parseWith jsonTreeTermParsers (pure . jsonTreeTerm blob) blob `catchError` jsonError blob

jsonError :: Applicative m => Blob -> SomeException -> m (Rendering.JSON.JSON "trees" SomeJSON)
jsonError blob (SomeException e) = pure $ renderJSONError blob (show e)

quietTerm :: (ParseEffects sig m, MonadIO m) => Blob -> m Builder
quietTerm blob = showTiming blob <$> time' ( asks showTermParsers >>= \ parsers -> parseWith parsers (fmap (const (Right ())) . showTerm) blob `catchError` timingError )
  where
    timingError (SomeException e) = pure (Left (show e))
    showTiming Blob{..} (res, duration) =
      let status = if isLeft res then "ERR" else "OK"
      in stringUtf8 (status <> "\t" <> show (blobLanguage blob) <> "\t" <> blobPath blob <> "\t" <> show duration <> " ms\n")


type ParseEffects sig m = (Member (Error SomeException) sig, Member (Reader PerLanguageModes) sig, Member Parse sig, Member (Reader Config) sig, Carrier sig m)


showTermParsers :: PerLanguageModes -> Map Language (SomeParser ShowTerm Loc)
showTermParsers = allParsers

class ShowTerm term where
  showTerm :: (Carrier sig m, Member (Reader Config) sig) => term Loc -> m Builder

instance (Functor syntax, Show1 syntax) => ShowTerm (Term syntax) where
  showTerm = serialize Show . quieterm

instance ShowTerm Java.Term where
  showTerm = serialize Show . void . Java.getTerm

instance ShowTerm JSON.Term where
  showTerm = serialize Show . void . JSON.getTerm

instance ShowTerm PythonPrecise.Term where
  showTerm = serialize Show . void . PythonPrecise.getTerm


instance ShowTerm Go.Term where
  showTerm = showTerm . cata Term
instance ShowTerm Markdown.Term where
  showTerm = showTerm . cata Term
instance ShowTerm PHP.Term where
  showTerm = showTerm . cata Term
instance ShowTerm PythonALaCarte.Term where
  showTerm = showTerm . cata Term
instance ShowTerm Ruby.Term where
  showTerm = showTerm . cata Term
instance ShowTerm TSX.Term where
  showTerm = showTerm . cata Term
instance ShowTerm TypeScript.Term where
  showTerm = showTerm . cata Term


sexprTermParsers :: PerLanguageModes -> Map Language (SomeParser SExprTerm Loc)
sexprTermParsers = allParsers

class SExprTerm term where
  sexprTerm :: term Loc -> Builder

instance (ConstructorName syntax, Foldable syntax, Functor syntax) => SExprTerm (Term syntax) where
  sexprTerm = SExpr.serializeSExpression ByConstructorName

instance SExprTerm Java.Term where
  sexprTerm = SExpr.Precise.serializeSExpression . Java.getTerm

instance SExprTerm JSON.Term where
  sexprTerm = SExpr.Precise.serializeSExpression . JSON.getTerm

instance SExprTerm PythonPrecise.Term where
  sexprTerm = SExpr.Precise.serializeSExpression . PythonPrecise.getTerm


instance SExprTerm Go.Term where
  sexprTerm = SExpr.serializeSExpression ByConstructorName
instance SExprTerm Markdown.Term where
  sexprTerm = SExpr.serializeSExpression ByConstructorName
instance SExprTerm PHP.Term where
  sexprTerm = SExpr.serializeSExpression ByConstructorName
instance SExprTerm PythonALaCarte.Term where
  sexprTerm = SExpr.serializeSExpression ByConstructorName
instance SExprTerm Ruby.Term where
  sexprTerm = SExpr.serializeSExpression ByConstructorName
instance SExprTerm TSX.Term where
  sexprTerm = SExpr.serializeSExpression ByConstructorName
instance SExprTerm TypeScript.Term where
  sexprTerm = SExpr.serializeSExpression ByConstructorName


dotGraphTermParsers :: Map Language (SomeParser DOTGraphTerm Loc)
dotGraphTermParsers = aLaCarteParsers

class DOTGraphTerm term where
  dotGraphTerm :: (Carrier sig m, Member (Reader Config) sig) => term Loc -> m Builder

instance (ConstructorName syntax, Foldable syntax, Functor syntax) => DOTGraphTerm (Term syntax) where
  dotGraphTerm = serialize (DOT (termStyle "terms")) . renderTreeGraph

instance DOTGraphTerm Go.Term where
  dotGraphTerm = serialize (DOT (termStyle "terms")) . renderTreeGraph
instance DOTGraphTerm Markdown.Term where
  dotGraphTerm = serialize (DOT (termStyle "terms")) . renderTreeGraph
instance DOTGraphTerm PHP.Term where
  dotGraphTerm = serialize (DOT (termStyle "terms")) . renderTreeGraph
instance DOTGraphTerm PythonALaCarte.Term where
  dotGraphTerm = serialize (DOT (termStyle "terms")) . renderTreeGraph
instance DOTGraphTerm Ruby.Term where
  dotGraphTerm = serialize (DOT (termStyle "terms")) . renderTreeGraph
instance DOTGraphTerm TSX.Term where
  dotGraphTerm = serialize (DOT (termStyle "terms")) . renderTreeGraph
instance DOTGraphTerm TypeScript.Term where
  dotGraphTerm = serialize (DOT (termStyle "terms")) . renderTreeGraph


jsonTreeTermParsers :: Map Language (SomeParser JSONTreeTerm Loc)
jsonTreeTermParsers = aLaCarteParsers

class JSONTreeTerm term where
  jsonTreeTerm :: Blob -> term Loc -> Rendering.JSON.JSON "trees" SomeJSON

instance ToJSONFields1 syntax => JSONTreeTerm (Term syntax) where
  jsonTreeTerm = renderJSONTerm

instance JSONTreeTerm Go.Term where
  jsonTreeTerm blob = jsonTreeTerm blob . cata Term
instance JSONTreeTerm Markdown.Term where
  jsonTreeTerm blob = jsonTreeTerm blob . cata Term
instance JSONTreeTerm PHP.Term where
  jsonTreeTerm blob = jsonTreeTerm blob . cata Term
instance JSONTreeTerm PythonALaCarte.Term where
  jsonTreeTerm blob = jsonTreeTerm blob . cata Term
instance JSONTreeTerm Ruby.Term where
  jsonTreeTerm blob = jsonTreeTerm blob . cata Term
instance JSONTreeTerm TSX.Term where
  jsonTreeTerm blob = jsonTreeTerm blob . cata Term
instance JSONTreeTerm TypeScript.Term where
  jsonTreeTerm blob = jsonTreeTerm blob . cata Term


jsonGraphTermParsers :: Map Language (SomeParser JSONGraphTerm Loc)
jsonGraphTermParsers = aLaCarteParsers

class JSONGraphTerm term where
  jsonGraphTerm :: Blob -> term Loc -> ParseTreeFileGraph

instance (Foldable syntax, Functor syntax, ConstructorName syntax) => JSONGraphTerm (Term syntax) where
  jsonGraphTerm blob t
    = let graph = renderTreeGraph t
          toEdge (Edge (a, b)) = defMessage & P.source .~ a^.vertexId & P.target .~ b^.vertexId
          path = T.pack $ blobPath blob
          lang = bridging # blobLanguage blob
      in defMessage
          & P.path .~ path
          & P.language .~ lang
          & P.vertices .~ vertexList graph
          & P.edges .~ fmap toEdge (edgeList graph)
          & P.errors .~ mempty

instance JSONGraphTerm Go.Term where
  jsonGraphTerm blob = jsonGraphTerm blob . cata Term
instance JSONGraphTerm Markdown.Term where
  jsonGraphTerm blob = jsonGraphTerm blob . cata Term
instance JSONGraphTerm PHP.Term where
  jsonGraphTerm blob = jsonGraphTerm blob . cata Term
instance JSONGraphTerm PythonALaCarte.Term where
  jsonGraphTerm blob = jsonGraphTerm blob . cata Term
instance JSONGraphTerm Ruby.Term where
  jsonGraphTerm blob = jsonGraphTerm blob . cata Term
instance JSONGraphTerm TSX.Term where
  jsonGraphTerm blob = jsonGraphTerm blob . cata Term
instance JSONGraphTerm TypeScript.Term where
  jsonGraphTerm blob = jsonGraphTerm blob . cata Term
