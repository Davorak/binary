{-# OPTIONS_GHC -fglasgow-exts #-}
-- for unboxed shifts

-----------------------------------------------------------------------------
-- |
-- Module      : Data.Binary.Builder
-- Copyright   : Lennart Kolmodin, Ross Paterson
-- License     : BSD3-style (see LICENSE)
-- 
-- Maintainer  : Lennart Kolmodin <kolmodin@dtek.chalmers.se>
-- Stability   : experimental
-- Portability : portable to Hugs and GHC
--
-- Efficient construction of lazy bytestrings.
--
-----------------------------------------------------------------------------

#if defined(__GLASGOW_HASKELL__) && !defined(__HADDOCK__)
#include "MachDeps.h"
#endif

module Data.Binary.Builder (

    -- * The Builder type
      Builder
    , toLazyByteString

    -- * Constructing Builders
    , empty
    , singleton
    , append
    , fromByteString        -- :: S.ByteString -> Builder
    , fromLazyByteString    -- :: L.ByteString -> Builder

    -- * Flushing the buffer state
    , flush

    -- * Derived Builders
    -- ** Big-endian writes
    , putWord16be           -- :: Word16 -> Builder
    , putWord32be           -- :: Word32 -> Builder
    , putWord64be           -- :: Word64 -> Builder

    -- ** Little-endian writes
    , putWord16le           -- :: Word16 -> Builder
    , putWord32le           -- :: Word32 -> Builder
    , putWord64le           -- :: Word64 -> Builder

  ) where

import Foreign
import Data.Monoid
import Data.Word
import Data.ByteString.Base (inlinePerformIO)
import qualified Data.ByteString      as S
import qualified Data.ByteString.Base as S
import qualified Data.ByteString.Lazy as L

#if defined(__GLASGOW_HASKELL__) && !defined(__HADDOCK__)
import GHC.Base
import GHC.Word (Word32(..),Word16(..),Word64(..))
#endif

------------------------------------------------------------------------

-- | A 'Builder' is an efficient way to build lazy 'L.ByteString's.
-- There are several functions for constructing 'Builder's, but only one
-- to inspect them: to extract any data, you have to turn them into lazy
-- 'L.ByteString's using 'toLazyByteString'.
--
-- Internally, a 'Builder' constructs a lazy 'L.Bytestring' by filling byte
-- arrays piece by piece.  As each buffer is filled, it is \'popped\'
-- off, to become a new chunk of the resulting lazy 'L.ByteString'.
-- All this is hidden from the user of the 'Builder'.

newtype Builder = Builder {
        -- Invariant (from Data.ByteString.Lazy):
        --      The lists include no null ByteStrings.
        runBuilder :: (Buffer -> [S.ByteString]) -> Buffer -> [S.ByteString]
    }

instance Monoid Builder where
    mempty  = empty
    mappend = append

------------------------------------------------------------------------

-- | /O(1)./ The empty Builder, satisfying
--
--  * @'toLazyByteString' 'empty' = 'L.empty'@
--
empty :: Builder
empty = Builder id

-- | /O(1)./ A Builder taking a single byte, satisfying
--
--  * @'toLazyByteString' ('singleton' b) = 'L.singleton' b@
--
singleton :: Word8 -> Builder
singleton = writeN 1 . flip poke
{-# INLINE singleton #-}

------------------------------------------------------------------------

-- | /O(1)./ The concatenation of two Builders, an associative operation
-- with identity 'empty', satisfying
--
--  * @'toLazyByteString' ('append' x y) = 'L.append' ('toLazyByteString' x) ('toLazyByteString' y)@
--
append :: Builder -> Builder -> Builder
append (Builder f) (Builder g) = Builder (f . g)

-- | /O(1)./ A Builder taking a 'S.ByteString', satisfying
--
--  * @'toLazyByteString' ('fromByteString' bs) = 'L.fromChunks' [bs]@
--
fromByteString :: S.ByteString -> Builder
fromByteString bs
  | S.null bs = empty
  | otherwise = flush `append` mapBuilder (bs :)

-- | /O(1)./ A Builder taking a lazy 'L.ByteString', satisfying
--
--  * @'toLazyByteString' ('fromLazyByteString' bs) = bs@
--
fromLazyByteString :: L.ByteString -> Builder
fromLazyByteString (S.LPS [])  = empty
fromLazyByteString (S.LPS bss) = flush `append` mapBuilder (bss ++)

------------------------------------------------------------------------

-- Our internal buffer type
data Buffer = Buffer {-# UNPACK #-} !(ForeignPtr Word8)
                     {-# UNPACK #-} !Int                -- offset
                     {-# UNPACK #-} !Int                -- used bytes
                     {-# UNPACK #-} !Int                -- length left

------------------------------------------------------------------------

-- | /O(n)./ Extract a lazy 'L.ByteString' from a 'Builder'.
-- The construction work takes place if and when the relevant part of
-- the lazy 'L.ByteString' is demanded.
--
toLazyByteString :: Builder -> L.ByteString
toLazyByteString m = S.LPS $ inlinePerformIO $ do
    buf <- newBuffer defaultSize
    return (runBuilder (m `append` flush) (const []) buf)

-- | /O(1)./ Pop the 'S.ByteString' we have constructed so far, if any,
-- yielding a new chunk in the result lazy 'L.ByteString'.
flush :: Builder
flush = Builder $ \ k buf@(Buffer p o u l) ->
    if u == 0
      then k buf
      else S.PS p o u : k (Buffer p (o+u) 0 l)

------------------------------------------------------------------------

--
-- copied from Data.ByteString.Lazy
--
defaultSize :: Int
defaultSize = 32 * k - overhead
    where k = 1024
          overhead = 2 * sizeOf (undefined :: Int)

------------------------------------------------------------------------

-- | Sequence an IO operation on the buffer
unsafeLiftIO :: (Buffer -> IO Buffer) -> Builder
unsafeLiftIO f =  Builder $ \ k buf -> inlinePerformIO $ do
    buf' <- f buf
    return (k buf')
{-# INLINE unsafeLiftIO #-}

-- | Get the size of the buffer
withSize :: (Int -> Builder) -> Builder
withSize f = Builder $ \ k buf@(Buffer _ _ _ l) ->
    runBuilder (f l) k buf

-- | Map the resulting list of bytestrings.
mapBuilder :: ([S.ByteString] -> [S.ByteString]) -> Builder
mapBuilder f = Builder (f .)

------------------------------------------------------------------------

-- | Ensure that there are at least @n@ many bytes available.
ensureFree :: Int -> Builder
ensureFree n = n `seq` withSize $ \ l ->
    if n <= l then empty else
        flush `append` unsafeLiftIO (const (newBuffer (max n defaultSize)))
{-# INLINE ensureFree #-}

-- | Ensure that @n@ many bytes are available, and then use @f@ to write some
-- bytes into the memory.
writeN :: Int -> (Ptr Word8 -> IO ()) -> Builder
writeN n f = ensureFree n `append` unsafeLiftIO (writeNBuffer n f)
{-# INLINE [1] writeN #-}

writeNBuffer :: Int -> (Ptr Word8 -> IO ()) -> Buffer -> IO Buffer
writeNBuffer n f (Buffer fp o u l) = do
    withForeignPtr fp (\p -> f (p `plusPtr` (o+u)))
    return (Buffer fp o (u+n) (l-n))
{-# INLINE writeNBuffer #-}

newBuffer :: Int -> IO Buffer
newBuffer size = do
    fp <- S.mallocByteString size
    return $! Buffer fp 0 0 size

------------------------------------------------------------------------

--
-- We rely on the fromIntegral to do the right masking for us.
-- The inlining here is critical, and can be worth 4x performance
--

-- | Write a Word16 in big endian format
putWord16be :: Word16 -> Builder
putWord16be w = writeN 2 $ \p -> do
    poke p               (fromIntegral (shiftr_w16 w 8) :: Word8)
    poke (p `plusPtr` 1) (fromIntegral (w)              :: Word8)
{-# INLINE putWord16be #-}

-- | Write a Word16 in little endian format
putWord16le :: Word16 -> Builder
putWord16le w = writeN 2 $ \p -> do
    poke p               (fromIntegral (w)              :: Word8)
    poke (p `plusPtr` 1) (fromIntegral (shiftr_w16 w 8) :: Word8)
{-# INLINE putWord16le #-}

-- putWord16le w16 = writeN 2 (\p -> poke (castPtr p) w16)

-- | Write a Word32 in big endian format
putWord32be :: Word32 -> Builder
putWord32be w = writeN 4 $ \p -> do
    poke p               (fromIntegral (shiftr_w32 w 24) :: Word8)
    poke (p `plusPtr` 1) (fromIntegral (shiftr_w32 w 16) :: Word8)
    poke (p `plusPtr` 2) (fromIntegral (shiftr_w32 w  8) :: Word8)
    poke (p `plusPtr` 3) (fromIntegral (w)               :: Word8)
{-# INLINE putWord32be #-}

--
-- a data type to tag Put/Check. writes construct these which are then
-- inlined and flattened. matching Checks will be more robust with rules.
--

-- | Write a Word32 in little endian format
putWord32le :: Word32 -> Builder
putWord32le w = writeN 4 $ \p -> do
    poke p               (fromIntegral (w)               :: Word8)
    poke (p `plusPtr` 1) (fromIntegral (shiftr_w32 w  8) :: Word8)
    poke (p `plusPtr` 2) (fromIntegral (shiftr_w32 w 16) :: Word8)
    poke (p `plusPtr` 3) (fromIntegral (shiftr_w32 w 24) :: Word8)
{-# INLINE putWord32le #-}

-- on a little endian machine:
-- putWord32le w32 = writeN 4 (\p -> poke (castPtr p) w32)

-- | Write a Word64 in big endian format
putWord64be :: Word64 -> Builder
#if WORD_SIZE_IN_BITS < 64
--
-- To avoid expensive 64 bit shifts on 32 bit machines, we cast to
-- Word32, and write that
--
putWord64be w =
    let a = fromIntegral (shiftr_w64 w 32) :: Word32
        b = fromIntegral w                 :: Word32
    in writeN 8 $ \p -> do
    poke p               (fromIntegral (shiftr_w32 a 24) :: Word8)
    poke (p `plusPtr` 1) (fromIntegral (shiftr_w32 a 16) :: Word8)
    poke (p `plusPtr` 2) (fromIntegral (shiftr_w32 a  8) :: Word8)
    poke (p `plusPtr` 3) (fromIntegral (a)               :: Word8)
    poke (p `plusPtr` 4) (fromIntegral (shiftr_w32 b 24) :: Word8)
    poke (p `plusPtr` 5) (fromIntegral (shiftr_w32 b 16) :: Word8)
    poke (p `plusPtr` 6) (fromIntegral (shiftr_w32 b  8) :: Word8)
    poke (p `plusPtr` 7) (fromIntegral (b)               :: Word8)
#else
putWord64be w = writeN 8 $ \p -> do
    poke p               (fromIntegral (shiftr_w64 w 56) :: Word8)
    poke (p `plusPtr` 1) (fromIntegral (shiftr_w64 w 48) :: Word8)
    poke (p `plusPtr` 2) (fromIntegral (shiftr_w64 w 40) :: Word8)
    poke (p `plusPtr` 3) (fromIntegral (shiftr_w64 w 32) :: Word8)
    poke (p `plusPtr` 4) (fromIntegral (shiftr_w64 w 24) :: Word8)
    poke (p `plusPtr` 5) (fromIntegral (shiftr_w64 w 16) :: Word8)
    poke (p `plusPtr` 6) (fromIntegral (shiftr_w64 w  8) :: Word8)
    poke (p `plusPtr` 7) (fromIntegral (w)               :: Word8)
#endif
{-# INLINE putWord64be #-}

-- | Write a Word64 in little endian format
putWord64le :: Word64 -> Builder

#if WORD_SIZE_IN_BITS < 64
putWord64le w =
    let b = fromIntegral (shiftr_w64 w 32) :: Word32
        a = fromIntegral w                 :: Word32
    in writeN 8 $ \p -> do
    poke (p)             (fromIntegral (a)               :: Word8)
    poke (p `plusPtr` 1) (fromIntegral (shiftr_w32 a  8) :: Word8)
    poke (p `plusPtr` 2) (fromIntegral (shiftr_w32 a 16) :: Word8)
    poke (p `plusPtr` 3) (fromIntegral (shiftr_w32 a 24) :: Word8)
    poke (p `plusPtr` 4) (fromIntegral (b)               :: Word8)
    poke (p `plusPtr` 5) (fromIntegral (shiftr_w32 b  8) :: Word8)
    poke (p `plusPtr` 6) (fromIntegral (shiftr_w32 b 16) :: Word8)
    poke (p `plusPtr` 7) (fromIntegral (shiftr_w32 b 24) :: Word8)
#else
putWord64le w = writeN 8 $ \p -> do
    poke p               (fromIntegral (w)               :: Word8)
    poke (p `plusPtr` 1) (fromIntegral (shiftr_w64 w  8) :: Word8)
    poke (p `plusPtr` 2) (fromIntegral (shiftr_w64 w 16) :: Word8)
    poke (p `plusPtr` 3) (fromIntegral (shiftr_w64 w 24) :: Word8)
    poke (p `plusPtr` 4) (fromIntegral (shiftr_w64 w 32) :: Word8)
    poke (p `plusPtr` 5) (fromIntegral (shiftr_w64 w 40) :: Word8)
    poke (p `plusPtr` 6) (fromIntegral (shiftr_w64 w 48) :: Word8)
    poke (p `plusPtr` 7) (fromIntegral (shiftr_w64 w 56) :: Word8)
#endif
{-# INLINE putWord64le #-}

-- on a little endian machine:
-- putWord64le w64 = writeN 8 (\p -> poke (castPtr p) w64)

------------------------------------------------------------------------
-- Unchecked shifts

shiftr_w16 :: Word16 -> Int -> Word16
shiftr_w32 :: Word32 -> Int -> Word32
shiftr_w64 :: Word64 -> Int -> Word64

#if defined(__GLASGOW_HASKELL__) && !defined(__HADDOCK__)
shiftr_w16 (W16# w) (I# i) = W16# (w `uncheckedShiftRL#`   i)
shiftr_w32 (W32# w) (I# i) = W32# (w `uncheckedShiftRL#`   i)

#if WORD_SIZE_IN_BITS < 64
shiftr_w64 (W64# w) (I# i) = W64# (w `uncheckedShiftRL64#` i)

foreign import ccall unsafe "stg_uncheckedShiftRL64"     
    uncheckedShiftRL64#     :: Word64# -> Int# -> Word64#
#else
shiftr_w64 (W64# w) (I# i) = W64# (w `uncheckedShiftRL#` i)
#endif

#else
shiftr_w16 = shiftR
shiftr_w32 = shiftR
shiftr_w64 = shiftR
#endif