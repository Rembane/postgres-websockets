{-| This module provides the JWT claims validation. Since websockets and
    listening connections in the database tend to be resource intensive
    (not to mention stateful) we need claims authorizing a specific channel and
    mode of operation.
-}
module PostgRESTWS.Claims
  ( validateClaims
  ) where

import           Control.Lens
import           Data.Aeson            (Value (..), toJSON)
import           Data.Aeson.Lens
import qualified Data.HashMap.Strict   as M
import           Data.Maybe            (fromJust)
import           Data.Time.Clock       (NominalDiffTime)
import           Data.Time.Clock.POSIX (POSIXTime)
import           Protolude
import           Web.JWT               (binarySecret)
import qualified Web.JWT               as JWT


type Claims = M.HashMap Text Value
type ConnectionInfo = (ByteString, ByteString, Claims)

{-| Given a secret, a token and a timestamp it validates the claims and returns
    either an error message or a triple containing channel, mode and claims hashmap.
-}
validateClaims :: Maybe ByteString -> Text -> POSIXTime -> Either Text ConnectionInfo
validateClaims secret jwtToken time = do
  cl <- case jwtClaims jwtSecret jwtToken time of
    JWTClaims c -> Right c
    _           -> Left "Error"
  jChannel <- claimAsJSON "channel" cl
  jMode <- claimAsJSON "mode" cl
  channel <- value2BS jChannel
  mode <- value2BS jMode
  Right (channel, mode, cl)
  where
    jwtSecret = binarySecret <$> secret
    value2BS val = case val of
      String s -> Right $ encodeUtf8 s
      _        -> Left "claim is not string value"
    claimAsJSON :: Text -> Claims -> Either Text Value
    claimAsJSON name cl = case M.lookup name cl of
      Just el -> Right el
      Nothing -> Left (name <> " not in claims")


{- Private functions and types copied from postgrest

   This code duplication will be short lived since postgrest will migrate towards jose
   Then this library will use jose's verifyClaims and error types.
-}
{-|
  Possible situations encountered with client JWTs
-}
data JWTAttempt = JWTExpired
                | JWTInvalid
                | JWTMissingSecret
                | JWTClaims (M.HashMap Text Value)
                deriving Eq

{-|
  Receives the JWT secret (from config) and a JWT and returns a map
  of JWT claims.
-}
jwtClaims :: Maybe JWT.Secret -> Text -> NominalDiffTime -> JWTAttempt
jwtClaims _ "" _ = JWTClaims M.empty
jwtClaims secret jwt time =
  case secret of
     Nothing -> JWTMissingSecret
     Just s ->
       let mClaims = toJSON . JWT.claims <$> JWT.decodeAndVerifySignature s jwt in
       case isExpired <$> mClaims of
         Just True  -> JWTExpired
         Nothing    -> JWTInvalid
         Just False -> JWTClaims $ value2map $ fromJust mClaims
  where
    isExpired claims =
      let mExp = claims ^? key "exp" . _Integer
      in fromMaybe False $ (<= time) . fromInteger <$> mExp
    value2map (Object o) = o
    value2map _          = M.empty
