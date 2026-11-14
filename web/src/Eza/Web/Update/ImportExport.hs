{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Part of the client update function; see "Eza.Web.Update".
module Eza.Web.Update.ImportExport (handle) where

import Miso

import qualified Data.Text as T
import Eza.Web.Api
import Eza.Web.Interpreter
import Eza.Web.Logic.Model
import Eza.Web.Update.Common (putModel, refreshStats, refreshTags, reloadList)

handle :: Action -> Effect () () Model Action
handle = \case
    ImportStart -> triggerFileInput "import-file"
    ImportFileChosen -> do
        putModel (\m -> m{mImporting = True})
        submitImport ImportDone ImportFailed
    ImportDone response -> do
        putModel (\m -> m{mImporting = False, mImportReport = imrReport response})
        let inserted = imrInserted response
            existing = imrExisting response
            found = imrFound response
        notify
            ( T.pack
                ( "Imported "
                    <> show inserted
                    <> " of "
                    <> show found
                    <> " links ("
                    <> show existing
                    <> " already saved)"
                )
            )
            ToastOk
        reloadList
        refreshTags
        refreshStats
    ImportFailed err -> do
        putModel (\m -> m{mImporting = False})
        handleApiError err
    -- saved searches --------------------------------------------------------
    _ -> pure ()
