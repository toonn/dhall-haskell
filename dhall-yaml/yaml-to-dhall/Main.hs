{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE PatternGuards       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Control.Applicative (optional, (<|>))
import Control.Exception (SomeException)
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Version (showVersion)
import Dhall.JSONToDhall (Conversion, parseConversion)
import Dhall.Pretty (CharacterSet(..))
import Dhall.YamlToDhall (Options(..), dhallFromYaml)
import Options.Applicative (Parser, ParserInfo)

import qualified Control.Exception
import qualified Data.ByteString.Char8                     as BSL8
import qualified Data.Text.IO                              as Text.IO
import qualified Data.Text.Prettyprint.Doc                 as Pretty
import qualified Data.Text.Prettyprint.Doc.Render.Terminal as Pretty.Terminal
import qualified Data.Text.Prettyprint.Doc.Render.Text     as Pretty.Text
import qualified Dhall.Pretty
import qualified Dhall.YamlToDhall                         as YamlToDhall
import qualified GHC.IO.Encoding
import qualified Options.Applicative                       as Options
import qualified System.Console.ANSI                       as ANSI
import qualified System.Exit
import qualified System.IO                                 as IO
import qualified Paths_dhall_yaml                          as Meta

-- ---------------
-- Command options
-- ---------------

data CommandOptions
    = Default
        { schema     :: Maybe Text
        , conversion :: Conversion
        , file       :: Maybe FilePath
        , output     :: Maybe FilePath
        , ascii      :: Bool
        , plain      :: Bool
        }
    | Type
        { file       :: Maybe FilePath
        , output     :: Maybe FilePath
        , ascii      :: Bool
        , plain      :: Bool
        }
    | Version
    deriving (Show)

-- | Command info and description
parserInfo :: ParserInfo CommandOptions
parserInfo = Options.info
          (  Options.helper <*> parseOptions)
          (  Options.fullDesc
          <> Options.progDesc "Convert a YAML expression to a Dhall expression, given the expected Dhall type"
          )

-- | Parser for all the command arguments and options
parseOptions :: Parser CommandOptions
parseOptions =
        typeCommand
    <|> (   Default
        <$> optional parseSchema
        <*> parseConversion
        <*> optional parseFile
        <*> optional parseOutput
        <*> parseASCII
        <*> parsePlain
        )
    <|> parseVersion
  where
    typeCommand =
        Options.hsubparser
            (Options.command "type" info <> Options.metavar "type")
      where
        info = Options.info parser (Options.progDesc "Output the inferred Dhall type from a YAML value")
        parser =
                Type
            <$> optional parseFile
            <*> optional parseOutput
            <*> parseASCII
            <*> parsePlain

    parseSchema =
        Options.strArgument
            (  Options.metavar "SCHEMA"
            <> Options.help "Dhall type expression (schema)"
            )

    parseVersion =
        Options.flag'
            Version
            (  Options.long "version"
            <> Options.short 'V'
            <> Options.help "Display version"
            )

    parseFile =
        Options.strOption
            (   Options.long "file"
            <>  Options.help "Read YAML expression from a file instead of standard input"
            <>  Options.metavar "FILE"
            )

    parseOutput =
        Options.strOption
            (   Options.long "output"
            <>  Options.help "Write Dhall expression to a file instead of standard output"
            <>  Options.metavar "FILE"
            )

    parseASCII =
        Options.switch
            (   Options.long "ascii"
            <>  Options.help "Format code using only ASCII syntax"
            )

    parsePlain =
        Options.switch
            (   Options.long "plain"
            <>  Options.help "Disable syntax highlighting"
            )

-- ----------
-- Main
-- ----------

main :: IO ()
main = do
    GHC.IO.Encoding.setLocaleEncoding GHC.IO.Encoding.utf8

    options <- Options.execParser parserInfo

    let toCharacterSet ascii = case ascii of
            True  -> ASCII
            False -> Unicode

    let toBytes file = case file of
            Nothing   -> BSL8.getContents
            Just path -> BSL8.readFile path

    let renderExpression characterSet plain output expression = do
            let document = Dhall.Pretty.prettyCharacterSet characterSet expression

            let stream = Dhall.Pretty.layout document

            case output of
                Nothing -> do
                    supportsANSI <- ANSI.hSupportsANSI IO.stdout

                    let ansiStream =
                            if supportsANSI && not plain
                            then fmap Dhall.Pretty.annToAnsiStyle stream
                            else Pretty.unAnnotateS stream

                    Pretty.Terminal.renderIO IO.stdout ansiStream

                    Text.IO.putStrLn ""

                Just file_ ->
                    IO.withFile file_ IO.WriteMode $ \h -> do
                        Pretty.Text.renderIO h stream

                        Text.IO.hPutStrLn h ""

    case options of
        Version -> do
            putStrLn (showVersion Meta.version)

        Default{..} -> do
            let characterSet = toCharacterSet ascii

            handle $ do
                yaml <- toBytes file

                expression <- dhallFromYaml (Options schema conversion) yaml

                renderExpression characterSet plain output expression

        Type{..} -> do
            let characterSet = toCharacterSet ascii

            handle $ do
                yaml <- toBytes file

                schema <- YamlToDhall.schemaFromYaml yaml

                renderExpression characterSet plain output schema

handle :: IO a -> IO a
handle = Control.Exception.handle handler
  where
    handler :: SomeException -> IO a
    handler e = do
        IO.hPutStrLn IO.stderr ""
        IO.hPrint    IO.stderr e
        System.Exit.exitFailure
