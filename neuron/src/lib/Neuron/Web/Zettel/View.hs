{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Neuron.Web.Zettel.View
  ( renderZettel,
  )
where

import Data.Foldable (maximum)
import Data.TagTree
import Data.Tagged
import Data.Tree (Tree (..))
import qualified Neuron.Web.Query.View as Q
import Neuron.Web.Widget
import Neuron.Zettelkasten.Connection
import Neuron.Zettelkasten.Graph (ZettelGraph)
import qualified Neuron.Zettelkasten.Graph as G
import Neuron.Zettelkasten.ID (zettelIDSourceFileName)
import Neuron.Zettelkasten.Query.Error (QueryError, showQueryError)
import qualified Neuron.Zettelkasten.Query.Eval as Q
import Neuron.Zettelkasten.Zettel
import Reflex.Dom.Core hiding ((&))
import Reflex.Dom.Pandoc
import Relude hiding ((&))
import Text.Pandoc.Definition (Pandoc)

type AutoScroll = Tagged "autoScroll" Bool

renderZettel ::
  PandocBuilder t m =>
  Maybe Text ->
  AutoScroll ->
  (ZettelGraph, PandocZettel) ->
  m [QueryError]
renderZettel editUrl (Tagged autoScroll) (graph, (PandocZettel (z@Zettel {..}, zc))) = do
  let upTree = G.backlinkForest Folgezettel z graph
  whenNotNull upTree $ \_ -> do
    let attrs =
          "class" =: "flipped tree deemphasized"
            <> "id" =: "zettel-uptree"
            <> "style" =: "transform-origin: 50%"
    elAttr "nav" attrs $ do
      elClass "ul" "root" $ do
        el "li" $ do
          el "ul" $ do
            renderUplinkForest (\z2 -> G.getConnection z z2 graph) upTree
  -- Main content
  errors <- elAttr "div" ("class" =: "ui text container" <> "id" =: "zettel-container" <> "style" =: "position: relative") $ do
    when autoScroll $ do
      -- zettel-container-anchor is a trick used by the scrollIntoView JS below
      -- cf. https://stackoverflow.com/a/49968820/55246
      -- We use -24px (instead of -14px) here so as to not scroll all the way to
      -- title, and as to leave some of the tree visible as "hint" to the user.
      elAttr "div" ("id" =: "zettel-container-anchor" <> "style" =: "position: absolute; top: -24px; left: 0") blank
    divClass "zettel-view" $ do
      errors <- divClass "ui two column grid" $ do
        divClass "one wide tablet only computer only column" $ do
          renderActionsMenu VerticalMenu editUrl (Just z)
        divClass "sixteen wide mobile fifteen wide tablet fifteen wide computer stretched column" $ do
          errors <- renderZettelContent (handleZettelQuery graph) z zc
          renderZettelBottomPane graph z
          pure errors
      divClass "ui one column grid" $ divClass "mobile only sixteen wide column" $ do
        renderActionsMenu HorizontalMenu editUrl (Just z)
      pure errors
  -- Because the tree above can be pretty large, we scroll past it
  -- automatically when the page loads.
  -- FIXME: This may not scroll sufficiently if the images in the zettel haven't
  -- loaded (thus the browser doesn't known the final height yet.)
  when (autoScroll && not (null upTree)) $ do
    whenNotNull upTree $ \_ -> do
      el "script" $ text $
        "document.getElementById(\"zettel-container-anchor\").scrollIntoView({behavior: \"smooth\", block: \"start\"});"
  pure errors

renderZettelBottomPane :: DomBuilder t m => ZettelGraph -> Zettel -> m ()
renderZettelBottomPane graph z@Zettel {..} = do
  let cfBacklinks = nonEmpty $ G.backlinks OrdinaryConnection z graph
      tags = nonEmpty zettelTags
  when (isJust cfBacklinks || isJust tags)
    $ elClass "nav" "ui bottom attached segment deemphasized"
    $ do
      divClass "ui two column grid" $ do
        divClass "column" $ do
          whenJust cfBacklinks $ \links -> do
            elAttr "div" ("class" =: "ui header" <> "title" =: "Zettels that link here, but without branching") $
              text "More backlinks"
            el "ul" $ do
              forM_ links $ \zl ->
                el "li" $ Q.renderZettelLink Nothing def zl
        whenJust tags $
          divClass "column" . renderTags

handleZettelQuery ::
  (PandocRawConstraints m, DomBuilder t m, PandocRaw m) =>
  ZettelGraph ->
  m [QueryError] ->
  URILink ->
  m [QueryError]
handleZettelQuery graph oldRender uriLink = do
  case flip runReaderT (G.getZettels graph) (Q.evalQueryLink uriLink) of
    Left (Left -> e) -> do
      fmap (e :) oldRender <* elError e
    Right Nothing -> do
      oldRender
    Right (Just res) -> do
      Q.renderQueryResultIfSuccessful res >>= \case
        Nothing ->
          pure mempty
        Just (Right -> e) -> do
          fmap (e :) oldRender <* elError e
  where
    elError e =
      elClass "span" "ui left pointing red basic label" $ do
        text $ showQueryError e

renderUplinkForest ::
  DomBuilder t m =>
  (Zettel -> Maybe Connection) ->
  [Tree Zettel] ->
  m ()
renderUplinkForest getConn trees = do
  forM_ (sortForest trees) $ \(Node zettel subtrees) ->
    el "li" $ do
      divClass "forest-link" $
        Q.renderZettelLink (getConn zettel) def zettel
      when (length subtrees > 0) $ do
        el "ul" $ renderUplinkForest getConn subtrees
  where
    -- Sort trees so that trees containing the most recent zettel (by ID) come first.
    sortForest = reverse . sortOn maximum

renderZettelContent ::
  forall t m a.
  (PandocBuilder t m, Monoid a) =>
  (m a -> URILink -> m a) ->
  Zettel ->
  Pandoc ->
  m a
renderZettelContent handleLink Zettel {..} doc = do
  elClass "article" "ui raised attached segment zettel-content" $ do
    elClass "h1" "header" $ text zettelTitle
    x <- elPandoc (Config handleLink) doc
    whenJust zettelDay $ \day ->
      elAttr "div" ("class" =: "date" <> "title" =: "Zettel creation date") $ do
        elTime day
    pure x

renderTags :: DomBuilder t m => NonEmpty Tag -> m ()
renderTags tags = do
  forM_ tags $ \t -> do
    -- NOTE(ui): Ideally this should be at the top, not bottom. But putting it at
    -- the top pushes the zettel content down, introducing unnecessary white
    -- space below the title. So we put it at the bottom for now.
    elAttr "span" ("class" =: "ui right ribbon label zettel-tag" <> "title" =: "Tag") $ do
      elAttr
        "a"
        ( "href" =: (Q.tagUrl t)
            <> "class" =: "tag-inner"
            <> "title" =: ("See all zettels tagged '" <> unTag t <> "'")
        )
        $ text
        $ unTag t
    el "p" blank

------------------
-- Navigation menu
------------------
data MenuOrientation
  = VerticalMenu
  | HorizontalMenu
  deriving (Eq, Show, Ord)

renderActionsMenu :: DomBuilder t m => MenuOrientation -> Maybe Text -> Maybe Zettel -> m ()
renderActionsMenu orient editUrl mzettel = do
  let cls = case orient of
        VerticalMenu -> "ui deemphasized vertical icon menu"
        HorizontalMenu -> "ui deemphasized icon menu"
  elClass "nav" cls $ do
    divClass "item" $ do
      elAttr "a" ("href" =: "z-index.html" <> "title" =: "All Zettels (z-index)") $
        fa "fas fa-tree"
    whenJust ((,) <$> mzettel <*> editUrl) $ \(Zettel {..}, urlPrefix) ->
      divClass "item" $ do
        elAttr "a" ("href" =: (urlPrefix <> toText (zettelIDSourceFileName zettelID)) <> "title" =: "Edit this Zettel") $ fa "fas fa-edit"
    divClass "right item" $ do
      elAttr "a" ("href" =: "search.html" <> "title" =: "Search Zettels") $ fa "fas fa-search"
  where
    fa k = elClass "i" k blank