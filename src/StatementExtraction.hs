{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}

module StatementExtraction where

import Data.Text as DT
import Data.Binary
import Data.ByteArray
import qualified Crypto.PubKey.Ed25519 as Ed25519
import Data.Aeson
import Data.ByteArray (convert)
import GHC.Generics
import qualified Data.ByteString.Base16 as B16 (encode, decode)
import qualified Data.Text.Encoding as TE
import qualified Crypto.Hash as H (hash, digestFromByteString)
import Crypto.Hash.Algorithms (HashAlgorithm, Keccak_256)
import Crypto.Hash (Digest)
import qualified Data.Text.Encoding as TE
import Data.Binary as Binary (Binary(..), encode)
import Data.ByteString.Lazy (toStrict)

{-- imported from other sources --}

import System.Process
import GHC.IO.Handle
import System.Exit
import System.IO
import Text.ParserCombinators.Parsec
import Data.Char (isSpace)
import Text.ParserCombinators.Parsec.Number (decimal, int, nat)
import Data.Maybe (fromMaybe)
import Data.Either (lefts, rights)
import qualified Data.List as DL 
import Foreign.Marshal.Alloc (mallocBytes, free)
import qualified Data.ByteString as DBS (hGet)
import qualified Data.Map as Map
import Data.Maybe (catMaybes)
import qualified Data.String.Utils as SU
import Data.Foldable (foldlM)
import qualified Data.Time as Time (getCurrentTime)
import qualified System.Directory as SD (doesFileExist)

data HashAlgorithm a =>
     Hash a = Hash (Digest a)
              deriving (Eq, Ord, Show)

instance (HashAlgorithm a) => ToJSON (Hash a) where
  toJSON (Hash d) = String . TE.decodeUtf8 . B16.encode $ convert d


type SecretKey = Ed25519.SecretKey
type PublicKey = Ed25519.PublicKey
type Signature = Ed25519.Signature


instance ToJSON PublicKey where
  toJSON = String . TE.decodeUtf8 . B16.encode . convert

instance ToJSON Signature where
  toJSON = String . TE.decodeUtf8 . B16.encode . convert


type Id = Keccak_256

hash :: (ByteArrayAccess ba, HashAlgorithm a) => ba -> Hash a
hash = Hash . H.hash

data Code = CoqText Text
            deriving (Eq, Show, Generic)

fromCode :: Code -> Text
fromCode (CoqText t) = t 

data Kind = Unknown | Definition | Theorem | Notation | Tactic | Variable | Constructor | Proof | Library | Module | Section | Inductive | Axiom | Scheme | ModType | Instance | SynDef | Class | Record | Projection | Method
            deriving (Eq, Show, Generic)

instance Binary Text where
  put = put . DT.unpack
  get = get >>= return . DT.pack

instance Binary Code where
  put (CoqText a) = put a
  get = get >>= \a -> return (CoqText a)

-- refactoring needed
instance Binary Kind where
  put Unknown = putWord8 255
  put Definition = putWord8 0
  put Theorem = putWord8 1
  put Notation = putWord8 2
  put Tactic = putWord8 3
  put Variable = putWord8 4
  put Constructor = putWord8 5
  put Proof = putWord8 6
  put Library = putWord8 7
  put Module = putWord8 8
  put Section = putWord8 9
  put Inductive = putWord8 10
  put Axiom = putWord8 11
  put Scheme = putWord8 12
  put ModType = putWord8 13
  put Instance = putWord8 14
  put SynDef = putWord8 15
  put Class = putWord8 16
  put Record = putWord8 17
  put Projection = putWord8 18
  put Method = putWord8 19
  get = do
    tag_ <- getWord8
    case tag_ of
      255 -> return Unknown
      0 -> return Definition
      1 -> return Theorem
      2 -> return Notation
      3 -> return Tactic
      4 -> return Variable
      5 -> return Constructor
      6 -> return Proof
      7 -> return Library
      8 -> return Module
      9 -> return Section
      10 -> return Inductive
      11 -> return Axiom
      12 -> return Scheme
      13 -> return ModType
      14 -> return Instance
      15 -> return SynDef
      16 -> return Class
      17 -> return Record
      18 -> return Projection
      19 -> return Method
      _ -> fail "Binary_Kind_get: Kind cannot be parsed"

instance Binary Id where
 put _ = putWord8 0
 get  = do
    tag_ <- getWord8
    case tag_ of
      0 -> return undefined
      _ -> fail "no parse"

instance Binary (Digest Id) where
 put _ = putWord8 0
 get  = do
    tag_ <- getWord8
    case tag_ of
      0 -> return undefined
      _ -> fail "no parse"

 
instance Binary (Hash Id) where
   put (Hash d) = put . B16.encode $ convert d
   get = get >>= \a -> return (Hash a)

{----------------------------------------------------------}

class Identifiable a where
  id :: a -> Hash Id

data StatementA a = Statement { name :: Text
                              , kind :: Kind
                              , code :: Code
                              , source:: String -- source filename isomorphism
                              , uses :: [a]
                           } deriving (Eq, Show, Generic)

type Statement = StatementA (Hash Id)

instance Binary Statement where
  put s = do
           put (name s)
           put (kind s)
           put (code s)
           put (source s)
           put (uses s)
  get = do n <- get
           k <- get
           c <- get
           sc <- get
           u <- get
           return $ Statement n k c sc u


{-- instance Identifiable Statement where
  id = hash . toStrict . Binary.encode

instance Identifiable Text where
  id = hash . toStrict . Binary.encode

instance Identifiable Kind where
  id = hash . toStrict . Binary.encode
--}

newtype ByBinary a = ByBinary a

instance (Binary a) => (Identifiable (ByBinary a)) where
  id (ByBinary x) = hash . toStrict . Binary.encode $ x


type GlobFileDigest = String

type GlobFileName = String

data GlobFileRawEntry = GlobFileRawEntry {espos:: Int,
                                    eepos:: Int,
                                    ekind:: Kind,
                                    elibname:: String,
                                    emodname:: String,
                                    ename:: String} deriving (Eq, Show, Generic)

data GlobFileEntry = GlobFileResource GlobFileRawEntry | GlobFileStatement GlobFileRawEntry
                     deriving (Eq, Show, Generic)

type GlobFileData = (GlobFileDigest, GlobFileName, [GlobFileEntry])

globfileData :: Parser GlobFileData
globfileData = do
                dig <- globfileDigest
                newline
                name <- globfileName
                newline
                sts <- many (globfileStatement <|> globfileResource)
                return (dig, name, sts)


globfileDigest = string "DIGEST" >> spaces >> globfileIdent 
globfileName = char 'F' >> globfileIdent

-- TODO: Compare with Coq correct idents
-- .<>[]'_,:=/\\

globfileIdent = do
                 i <-  many1 (letter <|> digit <|> oneOf "._'")
                       <|> do {string "<>" ; return ""}
                 return $ trim i

globfileNot = many1 (letter <|> digit <|> oneOf ".<>[]'_,:=/\\+(){}!?*-|^~&@") >>= return . trim

--trim = f . f
--       where f = Prelude.reverse . Prelude.dropWhile isSpace

trim = SU.strip

globfileStatement = do
                     kind <-      do {try (string "def"); return Definition}
                              <|> do {try (string "not"); return Notation}
                              <|> do {try (string "ind"); return Inductive}
                              <|> do {try (string "constr"); return Constructor}
                              <|> do {try (string "prf"); return Proof}
                              <|> do {try (string "mod"); return Module}
                              <|> do {try (string "sec"); return Section}
                              <|> do {try (string "var"); return Variable}
                              <|> do {try (string "ax"); return Axiom}
                              <|> do {try (string "modtype"); return ModType}
                              <|> do {try (string "inst"); return Instance}
                              <|> do {try (string "syndef"); return SynDef}
                              <|> do {try (string "class"); return Class}
                              <|> do {try (string "rec"); return Record}
                              <|> do {try (string "proj"); return Projection}
                              <|> do {try (string "meth"); return Method} 
                     spaces
                     sbyte <- decimal
                     mebyte <- optionMaybe (char ':' >> decimal)                                                        
                     spaces
                     modname <- globfileIdent
                     spaces
                     name <- case kind of
                               Notation -> globfileNot
                               _ -> globfileIdent
                     newline                                         
                     return $ GlobFileStatement $ GlobFileRawEntry sbyte (fromMaybe sbyte mebyte) kind "" modname name

globfileResource =  do
                   char 'R'
                   sbyte <- decimal
                   char ':'
                   ebyte <- decimal
                   spaces
                   libname <- globfileIdent
                   spaces
                   modname <- globfileIdent
                   spaces                   
                   name <- globfileIdent <|> globfileNot
                   spaces
                   kind <-     do {try (string "var");  return Variable}
                           <|> do {try (string "defax");  return Axiom}
                           <|> do {try (string "def");  return Definition}
                           <|> do {try (string "not");  return Notation}
                           <|> do {try (string "ind");  return Inductive}
                           <|> do {try (string "constr");  return Constructor}
                           <|> do {try (string "thm");  return Theorem}
                           <|> do {try (string "lib");  return Library}
                           <|> do {try (string "modtype");  return ModType}
                           <|> do {try (string "mod");  return Module}
                           <|> do {try (string "sec");  return Section}
                           <|> do {try (string "prfax");  return Axiom}
                           <|> do {try (string "scheme");  return Scheme}
                           <|> do {try (string "inst");  return Instance}
                           <|> do {try (string "syndef"); return SynDef}
                           <|> do {try (string "class"); return Class}
                           <|> do {try (string "rec"); return Record}
                           <|> do {try (string "proj"); return Projection}
                           <|> do {try (string "meth"); return Method}
                   newline
                   return $ GlobFileResource $ GlobFileRawEntry sbyte ebyte kind libname modname name

type PreStatement = StatementA (Kind, Text)

data ResourceKind = Resource | StopStatement | IgnorableRes
                    deriving (Eq, Show, Generic)

-- Unknown | Definition | Theorem | Notation | Tactic | Variable | Constructor | Proof | Library | Module | Section | Inductive | Axiom | Scheme | ModType | Instance | SynDef | Class

resourceKind :: Kind -> ResourceKind
resourceKind Definition = Resource
resourceKind Instance = Resource
resourceKind Theorem = Resource
resourceKind Notation = StopStatement -- Resource cannot print them ATM 
resourceKind Tactic = Resource
resourceKind Variable = Resource
resourceKind Constructor = Resource
resourceKind Proof = Resource
resourceKind Library = IgnorableRes -- think of this
resourceKind Module = StopStatement
resourceKind Section = StopStatement
resourceKind Inductive = Resource
resourceKind Axiom = Resource
resourceKind Scheme =  IgnorableRes -- Resource cannot deal with schemes ATM
resourceKind Unknown = IgnorableRes
resourceKind ModType = StopStatement
resourceKind SynDef = Resource
resourceKind Class = Resource
resourceKind Record = Resource
resourceKind Projection = Resource
resourceKind Method = Resource

-- TODO: deal with multiple declarations without dots like
-- Variale a b: X.
-- Remove vernac comments
loadVernacCode :: String -> Int -> Maybe Int -> IO Code
loadVernacCode vfname pos1 (Just pos2) = do
                                     h <- openBinaryFile vfname ReadMode                                    
                                     hSeek h AbsoluteSeek (fromIntegral pos1)                                     
                                     let seekBackDot n = do
                                                        bs <- DBS.hGet h 1
                                                        -- seeking was at pos1 - (n-1)
                                                        if (TE.decodeUtf8 bs == ".") then return (n-1)
                                                        else do
                                                           -- putStrLn $ show n
                                                           if (pos1 >= n) then do  
                                                              hSeek h AbsoluteSeek (fromIntegral $ pos1 - n)
                                                              seekBackDot (n+1)
                                                           else do
                                                              hSeek h AbsoluteSeek 0
                                                              return n
                                     n <- seekBackDot 1 
                                     let sz = pos2 - pos1 + 1 + n                                      
                                     if (sz > 0) then do 
                                        bs <- DBS.hGet h sz
                                        hClose h  
                                        return $ CoqText $ DT.pack $ DL.dropWhileEnd (\c -> c/='.') $ trim $ DT.unpack $ TE.decodeUtf8 bs
                                     else
                                        return $ CoqText ""
loadVernacCode vfname pos1 Nothing = do
                                       h <- openBinaryFile vfname ReadMode
                                       lastpos <- hFileSize h
                                       loadVernacCode vfname pos1 (Just $ fromIntegral $ lastpos - 1)

fromGlobFileRawEntry :: GlobFileName -> GlobFileRawEntry -> Maybe (Int, PreStatement)
fromGlobFileRawEntry lib r = case (resourceKind $ ekind r) of
                           Resource ->
                              let ln = elibname r in
                              let pref' = if (Prelude.null ln) then lib else ln in
                              let mn = emodname r in
                              let pref = if (Prelude.null mn) then pref' else pref' ++ "." ++ mn in
                              let sn = ename r in
                              if (Prelude.null sn) then Nothing
                                  else   
                                    let fqn = DT.pack $ pref ++ "." ++ sn in
                                    Just ((espos r), Statement fqn (ekind r) (CoqText "") (show $ StatementExtraction.id $ ByBinary $  DT.pack "") [])
                           StopStatement -> Nothing
                           IgnorableRes -> Nothing

{--
GlobFileRawEntry {espos:: Int, eepos:: Int, ekind:: Kind, elibname:: String, emodname:: String, ename:: String}
data StatementA a = Statement { name :: Text, kind :: Kind, code :: Code, uses :: [a]} deriving (Eq, Show, Generic)
--}

collectStatements0 :: [GlobFileEntry] -> String -> GlobFileName -> Maybe (Int, PreStatement) -> Maybe Int -> [PreStatement] -> IO [PreStatement]
collectStatements0 [] vfname _ (Just (pos1, cs)) mpos2  accs = do
                                                              cd <- loadVernacCode vfname pos1 mpos2  
                                                              return (cs {code = cd}:accs)
collectStatements0 [] _ _ Nothing _  accs = return accs
collectStatements0 (s:ss) vfname libname pcs@(Just (pos1, cs)) mpos2 accs = 
            case s of
                GlobFileStatement r-> do
                                      -- putStrLn $ "Processing " ++ (show $ ekind r)
                                      case (ekind r, kind cs) of
                                        (Constructor, Inductive) ->                                              
                                             let pcons' = fromGlobFileRawEntry libname r in
                                             case pcons' of
                                               Nothing -> fail "Cannot collect constructor"
                                               Just (_, cons') -> 
                                                   let cons = cons' {uses=[(kind cs, name cs)]} in
                                                   collectStatements0 ss vfname libname pcs Nothing (cons:accs)
                                        (Constructor, _) -> fail "Meeting constructor when collecting not-Inductive"
                                        _ -> do
                                               cd <- loadVernacCode vfname pos1 (Just $ fromMaybe ((espos r) - 1)  mpos2)
                                               let accs' = (cs {code=cd}:accs)
                                               let newpcs = fromGlobFileRawEntry libname r
                                               collectStatements0 ss vfname libname newpcs Nothing accs'                     
                GlobFileResource r -> do
                                        -- putStrLn $ "Processing " ++ (show $ ekind r)
                                        case (resourceKind $ ekind r) of
                                         StopStatement -> 
                                                   let newpos2 = Just $ fromMaybe ((espos r) - 1) mpos2 in
                                                   collectStatements0 ss vfname libname pcs newpos2 accs
                                         Resource ->
                                                   let r' = fromGlobFileRawEntry libname r in
                                                   case r' of
                                                    Nothing -> collectStatements0 ss vfname libname pcs Nothing accs 
                                                    Just (_, rs) ->
                                                      let newpcs = Just (pos1, cs {uses = (kind rs, name rs):(uses cs)}) in
                                                      collectStatements0 ss vfname libname newpcs Nothing accs
                                         IgnorableRes -> collectStatements0 ss vfname libname pcs Nothing accs
collectStatements0 (s:ss) vfname libname Nothing _ accs =
            case s of
                GlobFileStatement r ->  let newpcs = fromGlobFileRawEntry libname r in
                                        collectStatements0 ss vfname libname newpcs Nothing accs                     
                GlobFileResource r ->   collectStatements0 ss vfname libname Nothing Nothing accs

collectStatements sts vfname libname = collectStatements0 sts vfname libname Nothing Nothing []


-- think of kind
eqStatement :: PreStatement -> PreStatement -> Bool
eqStatement s1 s2 = (name s1 == name s2) && (kind s1 == kind s2)

{--
GlobFileRawEntry {espos:: Int, eepos:: Int, ekind:: Kind, elibname:: String, emodname:: String, ename:: String}
data StatementA a = Statement { name :: Text, kind :: Kind, code :: Code, uses :: [a]} deriving (Eq, Show, Generic)
--}

spanEnd :: (a -> Bool) -> [a] -> ([a], [a])
spanEnd p l = let (l1,l2) = DL.span p $ DL.reverse l in
              (DL.reverse l2, DL.reverse l1)

-- NB!: if used constructor is declared inside internal module
-- need to look upper 
rereferInductives:: [PreStatement] -> [PreStatement]
rereferInductives sts = let m = Map.fromList $ DL.map (\s -> (name s, s)) sts in
                        let sts' = DL.map (\s -> s {uses = DL.map (\u ->
                                   let look st = let mref = Map.lookup st m in
                                                 case mref of
                                                   Nothing -> let (mod, name) = spanEnd (\c -> c/='.') $ DT.unpack st in
                                                              if (Prelude.null mod) then Nothing
                                                              else 
                                                                 let mod' = DL.dropWhileEnd (\c -> c/='.') $ DL.init mod in
                                                              let st' = DT.pack $ mod' ++ name in
                                                              if (st' == "") then Nothing
                                                                  else look st'
                                                   Just ref -> Just ref
                                   in let mref = look (snd u) in
                                   case mref of
                                     Nothing -> u
                                     Just ref -> (fst u, name ref)
                               ) $ uses s}) sts in
                        DL.map (\s -> s {uses = DL.map (\u -> if (fst u == Constructor) then
                                                           let mcons = Map.lookup (snd u) m in
                                                           case mcons of
                                                             Nothing -> u                                                             
                                                             Just cons -> if (Prelude.null $ uses cons) then u
                                                                          else Prelude.head $ uses cons
                                                              else u) $ uses s}) sts'

-- removes dublicates
-- removes dublicates in "uses"
-- removes self-referencing from "uses"
-- removes Variables from "uses" as they are referenced as Axioms
-- removes Constructors as Statements
adjustStatements :: [PreStatement] -> [PreStatement]
adjustStatements sts = -- DL.filter (\s -> kind s /= Constructor) $
                       DL.nubBy eqStatement $
                       DL.map (\s -> s{uses = DL.filter (\u -> u /= (kind s, name s) && fst u /= Variable) $ DL.nub $ uses s}) sts
                       -- $ rereferInductives sts

-- data StatementA a = Statement { name :: Text, kind :: Kind, code :: Code, uses :: [a]} deriving (Eq, Show, Generic)
-- ((name, code), filename)
preStatementPair :: PreStatement -> (String, String)
preStatementPair ps = -- ((snd $ spanEnd (\c -> c /= '.') $ DT.unpack $ name ps,
                          (DT.unpack $ fromCode $ code ps,
                          fst $ DL.span (\c -> c /= '.') $ DT.unpack $ name ps)
                             

removeStartFromString :: String -> String -> String
removeStartFromString [] s = s
removeStartFromString p [] = []
removeStartFromString pat@(p:pats) str@(s:strs) = if (isSpace p) then
                                                     removeStartFromString pats str
                                                  else if (isSpace s) then
                                                     removeStartFromString pat strs
                                                  else if (p == s) then
                                                     removeStartFromString pats strs
                                                  else str

removeEndFromString :: String -> String -> String
removeEndFromString pat str = DL.reverse $ removeStartFromString (DL.reverse pat) (DL.reverse str)

-- (statement, filename)
-- :: Library name -> statement kind -> statement name -> theory -> accumulated list of (statements, filenames) ->
-- (statement name, generated (or found file))    
generateUnresolvedFile:: GlobFileName -> Kind -> Text -> Map.Map Text PreStatement -> [(Text, String)] -> IO (Maybe (Text, String))
generateUnresolvedFile libname k sts thm filem =
                                    if (Map.member sts thm) || (resourceKind k /= Resource) then return Nothing
                                    else do
                                       let fqstname = DT.unpack sts
                                       date <- Time.getCurrentTime -- "2008-04-18 14:11:22.476894 UTC"
                                       let sname = "SE" ++ (trim $ DL.dropWhile (\c -> c/=' ') $ show $
                                                    StatementExtraction.id $ ByBinary (show date, sts)) 
                                       let fwPname = "WP" ++ sname ++ ".v"
                                       let fwCname = "WC" ++ sname ++ ".v"
                                       -- Coq.Init.Logic - loadable
                                       -- BinNat - loadable
                                       -- BinNat.N - not loadable
                                       -- try to load the item in full context modname = libname?
                                       putStrLn $ "Generating files for " ++ fqstname                                 
                                       let (modname, stname) =  spanEnd (\c -> c/='.') fqstname  
                                       writeFile fwPname ("Require Export " ++ libname ++ ".\nPrint " ++ fqstname ++ ".")
                                       -- Test Print Implicit instead of Check
                                       writeFile fwCname ("Require Export " ++ libname ++ ".\nPrint Implicit " ++ fqstname ++ ".")
                                       (ecP, s1P, _) <- readProcessWithExitCode "coqc" [fwPname] []
                                       (ecC, s1C, _) <- readProcessWithExitCode "coqc" [fwCname] []
                                       case ecP of
                                         ExitFailure _ -> do
                                                   putStrLn ("Error in coqc: " ++ fwPname)
                                                   return Nothing
                                         -- do not check this for Notations !!!
                                         --(_, ExitFailure _)-> do
                                         --          putStrLn ("Error in coqc: " ++ fwCname)
                                         --          return Nothing
                                         ExitSuccess -> do                                                   
                                                   let header = "Require Export " ++ libname ++ ".\n"
                                                   -- remove comments after empty line
                                                   let prebody = trim $ Prelude.head $ SU.split "\n\n" s1P
                                                   -- remove modules name from the extracted name, which is at the first line
                                                   let pretypename = SU.split ":" $ trim $ Prelude.head $ SU.split "\n\n" s1C 
                                                   let (shortname, typename) = (snd $ spanEnd (\c -> c/='.') $
                                                                                      Prelude.head pretypename,
                                                                                trim $ SU.join ":" $ Prelude.tail pretypename) 
                                                   let body =  (if (k == Definition) || (k == Theorem) || (k == Method) || (k == Class) then
                                                                "Definition " ++ shortname ++ " : " ++ typename ++ ":=\n" ++
                                                                (trim $ removeEndFromString (": " ++ typename) $ SU.join "=" $
                                                                 Prelude.tail $ SU.split "=" prebody)
                                                               else prebody) ++ "."
                                                   let newst = header ++ body
                                                   let idChunk = "BitFunctor" ++ (trim $ DL.dropWhile (\c -> c/=' ') $ show $
                                                                 StatementExtraction.id $ ByBinary $ modname ++ "\n" ++ body)
                                                   let mfile = Map.lookup idChunk $ Map.fromList $
                                                               DL.map (\(st, fn) -> (fn, st)) filem
                                                   bFileExists <- SD.doesFileExist $ idChunk ++ ".v"
                                                   if (bFileExists) then do
                                                                     putStrLn ("- file already generated")
                                                                     return $ Just (sts, idChunk)
                                                   else  case mfile of
                                                     Just _ -> do
                                                                     fail "- file generated but doesn't exist" 
                                                     Nothing -> do
                                                                 let thm' = Map.fromList $ DL.map (\(t,ps) -> (source ps, name ps))
                                                                                         $ Map.toList thm    
                                                                 let mfile2 = Map.lookup idChunk thm'
                                                                 case mfile2 of
                                                                   Just name -> do
                                                                                  putStrLn ("- found in the Theory, but file doesn't exist?")  
                                                                                  return $ Just (sts, idChunk)
                                                                   Nothing -> do
                                                                                let frname = idChunk ++ ".v"
                                                                                putStrLn $ "Writing chunk from " ++ modname
                                                                                            ++ ":\n" ++ newst
                                                                                writeFile frname newst
                                                                                return $ Just (sts, idChunk)
                                

--(a -> b -> a) -> a -> [b] -> a
--(b -> a -> m b) -> b -> t a -> m b
-- libname -> all new statements -> theory -> list of (sts, filenames) 
generateUnresolvedFiles:: GlobFileName -> [PreStatement] -> Map.Map Text PreStatement -> IO [(Text, String)]
generateUnresolvedFiles libname sts thm = do                                     
                                    mfiles <- foldlM (\fm u -> do
                                                               mts <- generateUnresolvedFile libname (fst u) (snd u) thm fm
                                                               case mts of
                                                                 -- already in theory or impossible to generate 
                                                                 Nothing -> return fm
                                                                 Just x -> return $ (x:fm)  
                                                         ) [] $ DL.nub $ Prelude.concat $ DL.map uses sts
                                    return $ DL.nub mfiles
                                        
 
changeStatement :: (Kind, Text) -> Map.Map Text String -> (Kind, Text)
changeStatement (k,t) m = let newst = Map.lookup t m in
                          let (s1, s2) = spanEnd (\c -> c/='.') $ DT.unpack t in
                          case newst of
                           Nothing -> (k,t)
                           Just s -> (k, DT.pack $ s ++ "." ++ s2)

-- seems to be ineffective
-- refactoring and optimization is needed
-- finally adjust  - remove all uses of the same Statement (with equal name and source hash)
-- remove such Statement - save only one !
-- remove all not found uses, hoping we are doing well :)

finalAdjustStatements:: [PreStatement] -> [PreStatement]
finalAdjustStatements sts = let thm = Map.fromList $ DL.map (\s -> (name s, s)) sts in
                            let m = Map.fromList $
                                    DL.map (\s-> ((source s, SU.join "." $ Prelude.tail $ SU.split "." $ DT.unpack $ name s), s)) sts in
                            let news' = Map.toList m in
                            let newthm'  = Map.fromList $ DL.map (\((_, sn), s) -> (sn, s)) news' in
                            let newthm  = Map.fromList $ DL.map (\(_, s) -> (name s, s)) news' in
                            let newsts = DL.map (\(_, s) -> s) news' in
                            --  DL.filter (\u -> fst u /= Unknown)
                            DL.map (\s -> s{uses =  DL.map
                              (\u -> let n = SU.join "." $ Prelude.tail $ SU.split "." $ DT.unpack $ snd u in
                                     if (Map.member (snd u) newthm) then u
                                     else let ms' = Map.lookup n newthm' in
                                          case ms' of
                                           Nothing -> u -- (Unknown, snd u)
                                           Just s' -> (fst u, name s')) $ uses s}) newsts
                            

extractStatements :: [String] -> [String] -> [PreStatement] -> IO [PreStatement]
-- TODO:>
-- convert to Statement
-- remove temporary files (here?)
extractStatements [] accf acc = return $ finalAdjustStatements $ rereferInductives acc
extractStatements (fn:fs) accf acc = do
                               -- (_, Just hout, _, _) <- createProcess (proc "coqc" ["-verbose", f]) {std_out = CreatePipe}
                               -- createProcess (proc "coqc" ["-verbose", f++".v"])
                            if (DL.elem fn accf) then do
                                                      putStrLn $ "File already processed: " ++ fn
                                                      extractStatements fs accf acc
                            else do
                               let vFile = fn ++ ".v"
                               let gFile = fn ++ ".glob"
                               (ec, s1, _) <- readProcessWithExitCode "coqc" [vFile] []
                               case ec of
                                 ExitFailure _ -> do
                                                   putStrLn ("Error in coqc: " ++ vFile)
                                                   extractStatements fs (fn:accf) acc
                                 ExitSuccess ->	 do
                                                   putStrLn ("coqc output:\n" ++ s1)
                                                   globfile  <- readFile gFile
                                                   -- vText <- readFile vFile
                                                   -- let fLine = Prelude.head $ Prelude.lines vText
                                                   --  let digest = "(* bitfunctor id: " ++ idChunk ++ " *)"
                                                   -- let mdig = if (SU.startswith "(* bitfunctor id: " fLine &&
                                                   --           SU.endswith " *)" fLine) then SU.replace "(* bitfunctor id: " ""$
                                                   --                                         SU.replace " *)" "" fLine
                                                   --        else ""
                                                   -- if (mdig /= fd) then fail $ "File signature incorrect: " ++ vFile
                                                   -- else 
                                                   case (parse globfileData "" globfile) of
                                                       Left err -> do
                                                                   putStrLn "Parse error: " >> print gFile >> print err
                                                                   extractStatements fs (fn:accf) acc
                                                       Right (dig, lib, ent)  -> do
                                                                   sts'' <- collectStatements ent vFile lib
                                                                   let sts' = DL.map (\s -> s{source = fn}) sts''
                                                                   let sts = adjustStatements sts'
                                                                   -- putStrLn $ "Found:\n" ++ (show sts'')
                                                                   let newacc = adjustStatements $ sts' ++ acc
                                                                   let thm = Map.fromList $ DL.map (\s -> (name s, s)) newacc
                                                                   -- (sts, fn)
                                                                   newfiles <- generateUnresolvedFiles lib sts thm
                                                                   let newnames = Map.fromList newfiles
                                                                   let newacc' = adjustStatements $ DL.map (\s -> s{uses = DL.map (\u -> changeStatement u newnames) $ uses s}) newacc
                                                                   -- putStrLn $ "Change to:\n" ++ (show newnames)
                                                                   let newfiles' = DL.nub $ (DL.map snd newfiles) ++ fs
                                                                   -- putStrLn $ show newacc' 
                                                                   putStrLn $ "File " ++ fn ++ " has been processed, remaining " ++ (show $ DL.length newfiles')
                                                                   -- return []
                                                                   extractStatements newfiles' (fn:accf) newacc'
                                      
