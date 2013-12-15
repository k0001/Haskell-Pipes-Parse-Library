{-# OPTIONS_GHC -fno-warn-unused-imports #-}

{-| @pipes-parse@ builds upon @pipes@ to add several missing features necessary
    to implement 'Parser's:

    * End-of-input detection, so that 'Parser's can react to an exhausted input
      stream

    * Leftovers support, which simplifies several parsing problems

    * Connect-and-resume, to connect a 'Producer' to a 'Parser' and retrieve
      unused input
-}

module Pipes.Parse.Tutorial (
    -- * Overview
    -- $overview

    -- * Parsers
    -- $parsers

    -- * Lenses
    -- $lenses

    -- * FreeT
    -- $freeT

    -- * Conclusion
    -- $conclusion
    ) where

import Pipes
import Pipes.Parse

{- $overview
    @pipes-parse@ centers on three abstractions:

    * 'Producer's, unchanged from @pipes@, such as:

> producer :: Producer a m x

    * 'Lens''es between 'Producer's, which play a role analogous to 'Pipe's:

> lens :: Lens' (Producer a m x) (Producer b m y)

    * 'Parser's, which play a role analogous to 'Consumer's:

> parser :: Parser b m r

    There are four ways to connect these three abstractions:

    * Connect 'Producer's to 'Parser's using 'runStateT' \/ 'evalStateT' \/
      'execStateT':

> runStateT  :: Parser a m r -> Producer a m x -> m (r, Producer a m x)
> evalStateT :: Parser a m r -> Producer a m x -> m  r
> execStateT :: Parser a m r -> Producer a m x -> m (   Producer a m x)
>
> evalStateT parser producer :: m r


    * Connect 'Lens''s to 'Parser'es using 'zoom'

> zoom :: Lens' (Producer a m x) (Producer b m y)
>      -> Parser b m r
>      -> Parser a m r
>
> zoom lens parser :: Parser a m r

    * Connect 'Producer's to 'Lens''es using 'view' or ('^.'):

> view, (^.)
>     :: Producer a m x
>     -> Lens' (Producer a m x) (Producer b m y)
>     -> Producer b m y
>
> producer^.lens :: Producer b m r

    * Connect 'Lens''es to 'Lens''es using ('.') (i.e. function composition):

> (.) :: Lens' (Producer a m x) (Producer b m y)
>     -> Lens' (Producer b m y) (Producer c m z)
>     -> Lens' (Producer a m x) (Producer c m z)
-}

{- $parsers
    'Parser's handle end-of-input and pushback by storing a 'Producer' in a
    'StateT' layer:

> type Parser a m r = forall x . StateT (Producer a m x) m r

    To draw a single element from the underlying 'Producer', use the 'draw'
    command:

> draw :: (Monad m) => Parser a m (Maybe a)

    'draw' returns the next element from the 'Producer' wrapped in 'Just' or
    returns 'Nothing' if the underlying 'Producer' is empty.  Here's an example
    'Parser' written using 'draw' that retrieves the first two elements from a
    stream:

> import Control.Applicative (liftA2)
> import Pipes.Parse
>
> drawTwo :: (Monad m) => Parser a m (Maybe (a, a))
> drawTwo = do
>     mx <- draw
>     my <- draw
>     return (liftA2 (,) mx my)

    Since a 'Parser' is just a 'StateT' action, you run a 'Parser' using the
    same run functions as 'StateT':

> -- Feed a 'Producer' to a 'Parser', returning the result and leftovers
> runStateT  :: Parser a m r -> Producer a m x -> m (r, Producer a m x)
>
> -- Feed a 'Producer' to a 'Parser', returning only the result
> evalStateT :: Parser a m r -> Producer a m x -> m  r
>
> -- Feed a 'Producer' to a 'Parser', returning only the leftovers
> execStateT :: Parser a m r -> Producer a m x -> m (   Producer a m x)

    All three of these functions require a 'Producer' which we feed to the
    'Parser'.  For example, we can feed a pure stream of natural numbers:

>>> import qualified Pipes.Prelude as P
>>> evalStateT drawTwo P.stdinLn
Pink<Enter>
Elephants<Enter>
Just ("Pink", "Elephants")

    The result is wrapped in a 'Maybe' because our 'Producer' might have less
    than two elements:

>>> evalStateT drawTwo (yield 0)
Nothing

    If either of our two 'draw's fails and returns 'Nothing', the combined
    result will be 'Nothing'.
-}

{- $lenses
    @pipes-parse@ also provides a convenience function for testing purposes that
    draws all remaining elements and returns them as a list:

> drawAll :: (Monad m) => Parser a m [a]

    For example:

>>> import Pipes
>>> import Pipes.Parse
>>> evalStateT drawAll (each [1..10])
[1,2,3,4,5,6,7,8,9,10]

    However, this function is not recommended in general because it loads the
    entire input into memory, which defeats the purpose of streaming parsing:

>>> evalStateT drawAll (each [1..])
<Does not terminate>

    But what if you wanted to draw just the first ten elements from an infinite
    stream?  This is what lenses are for:

> import Pipes
> import Pipes.Parse
>
> drawThree :: (Monad m) => Parser a m [a]
> drawThree = zoom (splitsAt 3) drawAll

    'zoom' lets you delimit a 'Parser' using a 'Lens'.  The above code says to
    limit 'drawAll' to a subset of the input, in this case the first 10
    elements:

>>> evalStateT drawThree (each [1..])
[1,2,3]

    'splitsAt' is a 'Lens' with the following type:

> splitsAt
>     :: (Monad m)
>     => Int -> Lens' (Producer a m x) (Producer a m (Producer a m x))

    The easiest way to understand 'splitsAt' is to study what happens when you
    use it as a getter:

> view (splitsAt 3) :: Producer a m x -> Producer a m (Producer a m x) 

    In this context, @(splitsAt 3)@ behaves like 'splitAt' from the Prelude,
    except instead of splitting a list it splits a 'Producer'.  The outer
    'Producer' contains up to 3 elements and the inner 'Producer' contains the
    remainder of the elements.

>>> :set -XNoMonomorphismRestriction
>>> let outer = view (splitsAt 3) (each [1..6])  -- or: each [1..6]^.splitsAt 3
>>> inner <- runEffect $ for outer (lift . print)
1
2
3
>>> runEffect $ for inner (lift . print)
4
5
6

    'zoom' takes our lens a step further and uses it to limit our parser to the
    outer 'Producer' (the first 10 elements).  When the parser is done 'zoom'
    also returns unused elements back to the original stream.  We can
    demonstrate this using the following example parser:

> splitExample :: (Monad m) => Parser a m (Maybe a, [a])
> splitExample = do
>     x <- zoom (splitsAt 3) draw
>     y <- zoom (splitsAt 3) drawAll
>     return (x, y)

>>> evalStateT splitExample (each [1..])
(Just 1,[2,3,4])

    'spans' behaves the same way, except that it uses a predicate and takes as
    many consecutive elements as possible that satisfy the predicate:

> spanExample :: (Monad m) => Parser Int m (Maybe Int, [Int], Maybe Int)
> spanExample = do
>     x <- zoom (spans (>= 4)) draw
>     y <- zoom (spans (<  4)) drawAll
>     z <- zoom (spans (>= 4)) draw
>     return (x, y, z)

>>> evalStateT spanExample (each [1..])
(Nothing,[1,2,3],Just 4)

    You can even nest 'zoom's, too:

> nestExample :: (Monad m) => Parser Int m (Maybe Int, [Int], Maybe Int)
> nestExample = zoom (splitsAt 2) spanExample

>>> evalStateT nestExample (each [1..])
(Nothing,[1,2],Nothing)

    Note that 'zoom' nesting obeys the following two laws:

> zoom lens1 . zoom lens2 = zoom (lens1 . lens2)
>
> zoom id = id

    However, the lenses in this library are improper, meaning that they violate
    certain lens laws.  The consequence of this is that 'zoom' does not obey the
    monad morphism laws for these lenses.  For example:

> do x <- zoom (splitsAt 3) m  /=  zoom (splitsAt 3) $ do x <- m
>    zoom (splitsAt 3) (f x)                              f x
-}

{- $freeT
    @pipes-parse@ also provides convenient utilities for working with grouped
    streams in a list-like manner.  They analogy to list-like functions:

> -- '~' means "is analogous to"
> Producer a m ()            ~   [a]
>
> FreeT (Producer a m) m ()  ~  [[a]]

    'FreeT' nests each subsequent 'Producer' within the return value of the
    previous 'Producer' so that you cannot access the next 'Producer' until you
    completely drain the current 'Producer'.  However, you rarely need to work
    with 'FreeT' directly.  Instead, you structure everything using
    \"splitters\", \"transformations\" and \"joiners\":

    * Splitters: These split a 'Producer' into multiple sub-'Producer's
      delimited by 'FreeT':


> -- A "splitter"
> Producer a m ()           -> FreeT (Producer a m) m ()  ~   [a]  -> [[a]]
>
> -- A "transformation"
> FreeT (Producer a m) m () -> FreeT (Producer a m) m ()  ~  [[a]] -> [[a]]
>
> -- A "joiner"
> FreeT (Producer a m) m () -> Producer a m ()            ~  [[a]] ->  [a]

    An example splitter is @(view groups)@, which splits a 'Producer' into a
    'FreeT'-delimited 'Producer's, one for each group of consecutive equal
    elements:

> view groups :: (Eq a, Monad m) => Producer a m x -> FreeT (Producer a m) m x

    An example transformation is @(takes 3)@, which takes the first three
    'Producer's from a 'FreeT' and drops the rest:

> takes 3 :: (Monad m) => FreeT (Producer a m) m () -> FreeT (Producer a m) m ()

    An example joiner is 'concats', which collapses a 'FreeT' of 'Producer's
    back down into a single 'Producer':

> concats :: (Monad m) => FreeT (Producer a m) m x -> Producer a m x

    If you compose these three functions together, you will create a function
    that transforms a 'Producer' to keep only the first three groups of
    consecutive equal elements:

> concats . takes 3 . view groups
>     :: (Monad m) => Producer a m x -> Producer a m x

    For example:

>>> import Pipes.Parse
>>> import qualified Pipes.Prelude as P
>>> :set -XNoMonomorphismRestriction
>>> let threeGroups = concats . takes 3 . view groups
>>> runEffect $ threeGroups P.stdinLn >-> P.stdoutLn
1<Enter>
1
1<Enter>
1
2<Enter>
2
3<Enter>
3
3<Enter>
3
4<Enter>
>>> -- Note that the 4 is not echoed

    Both splitting and joining preserve the streaming nature of 'Producer's and
    do not buffer any values.  The transformed 'Producer' still outputs values
    immediately and does not wait for groups to complete before producing
    results.

    Also, lenses simplify things even further.  The reason that 'groups' is a
    lens is because it actually packages both a splitter and joiner into a
    single package.  We can then use 'over' to handle both the splitting and
    joining for us:

>>> runEffect $ over groups (takes 3) P.stdinLn >-> P.stdoutLn
<Exact same behavior>

    'over' takes care of calling the splitter before applying the
    transformation, then calling the joiner afterward.
-}

{- $conclusion
    @pipes-parse@ introduces core idioms for @pipes@-based parsing.  These
    idioms reuse 'Producer's, but introduce two new abstractions: 'Lens''es and
    'Parser's.

    This library is very minimal and only contains datatype-agnostic parsing
    utilities, so this tutorial does not explore the full range of parsing
    tricks using lenses.  See @pipes-bytestring@ and @pipes-text@ for more
    powerful examples of lens-based parsing.

    'Parser's are very straightforward to write, but lenses are more
    sophisticated.  If you are interested in writing your own custom lenses,
    study the implementation of 'splitsAt'.

    'FreeT' requires even greater sophistication.  Study how 'groupsBy' works to
    learn how to use 'FreeT' to introduce boundaries in a stream of 'Producer's.
    You can then use 'FreeT' to create your own custom splitters.

    To learn more about @pipes-parse@, ask questions, or follow development, you
    an subscribe to the @haskell-pipes@ mailing list at:

    <https://groups.google.com/forum/#!forum/haskell-pipes>

    ... or you can mail the list directly at:

    <mailto:haskell-pipes@googlegroups.com>
-}