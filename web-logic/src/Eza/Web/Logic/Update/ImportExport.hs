{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Part of the client update function; see "Eza.Web.Update".
module Eza.Web.Logic.Update.ImportExport (handle) where

import qualified Data.Text as T
import Eza.Web.Logic.Browser
import Eza.Web.Logic.Model
import Eza.Web.Logic.Requests
import Eza.Web.Logic.Update.Common
import Eza.Web.Logic.Update.Monad (Update)

handle :: Action -> Update ()
handle = \case
    ImportStart -> triggerFileInput "import-file"
    ImportFileChosen -> do
        putModel (\m -> m{gImport = (gImport m){ipImporting = True}})
        submitImport ImportDone ImportFailed
    ImportDone response -> do
        putModel (\m -> m{gImport = (gImport m){ipImporting = False, ipImportReport = imrReport response}})
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
        putModel (\m -> m{gImport = (gImport m){ipImporting = False}})
        handleApiError err
    -- saved searches --------------------------------------------------------
    _ -> pure ()
