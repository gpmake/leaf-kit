/// `LKLexer` is an opaque structure that wraps the lexing logic of Leaf-Kit.
///
/// Initialized with a `LKRawTemplate` (raw string-providing representation of a file or other source),
/// used by evaluating with `LKLexer.lex()` and either erroring or returning `[LKToken]`
internal struct LKLexer {
    // MARK: - Internal Initializers
    
    /// Init with `LKRawTemplate`
    init(_ template: LKRawTemplate) {
        self.src = template
        self.state = .raw

        self.entities = LKConf.entities
        self.openers = .init(entities.blockFactories.keys)
        self.openers.formUnion(entities.functions.keys)
        self.closers = .init()

        for (tag, factory) in entities.blockFactories {
            if let chained = factory as? ChainedBlock.Type {
                if chained.chainsTo.isEmpty { closers.insert("end" + tag) }
                else if chained.callSignature.isEmpty { closers.insert(tag) }
            } else { closers.insert("end" + tag) }
        }
    }

    // MARK: - Internal
    
    /// Lex the stored `LKRawTemplate`
    /// - Throws: `LeafError`
    /// - Returns: An array of fully built `LKTokens`, to then be parsed by `LKParser`
    mutating func lex() throws -> [LKToken] {
        while let next = try nextToken() { lexed.append(next) }
        return lexed
    }

    // MARK: - Private Only - Stored/Computed Properties
    private enum State {
        /// Parse as raw, until it finds `#` (but consuming escaped `\#`)
        case raw
        /// Start attempting to sequence tag-viable tokens (tagName, parameters, etc)
        case tag
        /// Start attempting to sequence parameters
        case parameters
        /// Start attempting to sequence a tag body
        case body
    }

    /// Current state of the Lexer
    private var state: State
    /// Current parameter depth, when in a Parameter-lexing state
    private var depth = 0
    /// Current index in `lexed`
    private var offset: Int { lexed.count - 1 }
    /// Stream of `LKTokens` that have been successfully lexed
    private var lexed: [LKToken] = []
    /// The originating template source content (ie, raw characters)
    private var src: LKRawTemplate
    /// Configured entitites
    private let entities: LeafEntities
    private var openers: Set<String>
    private var closers: Set<String>

    /// Convenience for the current character to read
    private var current: Character? { src.peek() }
    
    /// Convenience to pop the current character
    @discardableResult
    mutating private func pop() -> Character? { src.pop() }

    /// Convenience for an escaped tagIndicator token
    private let escapedTagID: LKToken = .raw(Character.tagIndicator.description)

    // MARK: - Private - Actual implementation of Lexer

    private mutating func nextToken() throws -> LKToken? {
        // if EOF, return nil - no more to read
        guard let first = current else { return nil }

        switch state {
            case .raw where first == .tagIndicator
                             : return lexCheckTagIndicator()
            case .tag where first.canStartIdentifier
                             : return try lexNamedTag()
            case .raw        : return lexRaw()
            case .tag        : return lexAnonymousTag()
            case .parameters : var part: LKToken?
                               repeat { part = try lexParameters() }
                                   while part == nil && current != nil
                               if let paramPart = part { return paramPart }
                               throw unknownError("Template ended on open parameters")
            default          : throw unknownError("Template cannot be lexed")
        }
    }

    private mutating func lexAnonymousTag() -> LKToken {
        state = .parameters
        depth = 0
        return .tag(nil)
    }

    private mutating func lexNamedTag() throws -> LKToken {
        let id = src.readWhile { $0.isValidInIdentifier }

        /// If not a recognized identifier decay to raw and rewrite tagIndicator
        guard openers.contains(id) || closers.contains(id) else {
            lexed[offset] = escapedTagID
            state = .raw;
            return .raw(id)
        }

        /// If the tag has parameters, and if it's a "closer" (end_xxxx, chained terminal tag eg: else)
        let xor = (params: current == .leftParenthesis, terminal: closers.contains(id))
        switch xor {
            /// Terminal chained tags can't have params (eg, else)
            case (true , true ) : throw unknownError("Closing tags can't have parameters")
            /// A normal tag call *must* have parameters, even if empty
            case (false, false) : throw unknownError("Tags must have parameters")
            /// Atomic function/block normal case
            case (true , false) : state = .parameters
                                  depth = 0
                                  return .tag(id)
            /// Terminal chained tag normal case
            case (false, true ) where openers.contains(id)
                                : if pop() != .colon {
                                    throw unknownError("Chained block missing `:`") }
                                  lexed.append(.tag(id))
                                  state = .raw
                                  return .blockMark
            /// End tag normal case
            case (false, true ) : state = .raw
                                  return .tag(id)
        }
    }

    /// Consume all data until hitting a `tagIndicator` that might open a tag/expression, escaping backslashed
    private mutating func lexRaw() -> LKToken {
        var slice = ""
        scan:
        while let first = current {
            let peek = src.peek(aheadBy: 1) ?? .backSlash /// Magic - \ can't be an ID start
            switch first {
                case .tagIndicator where peek.canStartIdentifier || peek == .leftParenthesis
                        : break scan
                case .backSlash where peek == .tagIndicator
                        : pop()
                          fallthrough
                case .tagIndicator, .backSlash
                        : slice.append(src.pop()!)
                default : slice += src.readWhileNot([.tagIndicator, .backSlash])
            }
        }
        return .raw(slice)
    }

    /// Consume `#`, change state to `.tag` or `.raw`, return appropriate token
    private mutating func lexCheckTagIndicator() -> LKToken {
        pop()
        let valid = current == .leftParenthesis || current?.canStartIdentifier ?? false
        state = valid ? .tag : .raw
        return valid ? .tagMark : escapedTagID
    }

    /// Parameter lexing - very monolithic, would be nice to break this up.
    private mutating func lexParameters() throws -> LKToken? {
        /// Consume first character regardless of what it is
        let first = pop()!

        /// Simple returning cases - .parametersStart/Delimiter/End, .literal(.string()), ParameterToken, space/comment discard
        switch first {
            case .tab, .newLine, .space
                                     : let x = src.readWhile {$0.isWhitespace}
                                       return retainWhitespace ? .whiteSpace(x) : nil
            case .leftParenthesis    : depth += 1
                                       return .paramsStart
            case .rightParenthesis where depth > 1
                                     : depth -= 1
                                       return .paramsEnd
            case .rightParenthesis   : state = .raw
                                       let body = current == .colon
                                       if body { pop()
                                                 lexed.append(.paramsEnd)
                                                 return .blockMark
                                       } else  { return .paramsEnd }
            case .comma              : return .paramDelimit
            case .colon where [.paramsStart,
                               .paramDelimit,
                               .param(.operator(.subOpen))].contains(lexed[offset - 1])
                                     : return .labelMark
            case .leftBracket where current == .rightBracket
                                     : pop()
                                       return .param(.literal(.emptyArray))
            case .leftBracket where current == .colon
                                     : pop()
                                       if current == .rightBracket {
                                            pop()
                                            return .param(.literal(.emptyDict))
                                       } else { throw unknownError("Expected empty dictionary literal") }
            case .underscore where current?.isWhitespace ?? false
                                     : return .param(.keyword(._))
            case .quote              :
                let read = src.readWhileNot([.quote, .newLine])
                if pop() != .quote { throw unterminatedString }
                return .param(.literal(.string(read)))
            case .tagIndicator       : /// A comment - silently discard
                src.readWhileNot([.tagIndicator])
                if pop() != .tagIndicator {
                    throw unknownError("Template ended in open comment") }
                return nil
            default                  : break
        }
        
        /// Complex ParameterToken lexing situations - enhanced to allow non-space separated values
        /// Complicated by overlap in acceptable isValidInParameter characters between possible types
        /// Process from most restrictive options to least to help prevent overly aggressive tokens
        /// Possible results, most restrictive to least
        /// * Operator
        /// * Constant(Int)
        /// * Constant(Double)
        /// * Keyword
        /// * Function Identifier
        /// * Variable Part Identifier

        /// If current character isn't valid for any kind of parameter, something's majorly wrong
        if !first.isValidInParameter { throw badToken(first) }
        /// Ensure peeking by one can always be unwrapped
        if current == nil { throw unknownError("Open parameters") }

        /// Test for Operator first - this will only handle max two character operators, not ideal
        /// Can't switch on this, MUST happen before trying to read tags
        if first.isValidOperator {
            /// Try to get a 2char Op first, then a 1 char Op if can't do 2
            let twoOp = LeafOperator(rawValue: String([first, current!]))
            let op = twoOp != nil ? twoOp! : LeafOperator(rawValue: String(first))!
            guard op.lexable else { throw badOperator(op) }
            if twoOp != nil { pop() }
            /// Handle ops that require no whitespace on one/both sides (does not handle subOpen leading)
            if [.evaluate, .scopeMember, .scopeRoot].contains(op) {
                if current!.isWhitespace {
                    throw unknownError("\(op) may not have trailing whitespace") }
                if op == .scopeMember, case .whiteSpace(_) = lexed[offset] {
                    throw unknownError("\(op) may not have leading whitespace") }
            }
            return .param(.operator(op))
        }

        /// Test for numerics next. This is not very intelligent but will read base2/8/10/16  for Ints and base
        /// 10/16 for decimal through native Swift initialization. Will not adequately decay to handle things
        /// like `0b0A` and recognize it as an invalid numeric.
        if first.canStartNumeric {
            var testInt: Int?
            var testDouble: Double?
            var radix: Int? = nil
            var sign = 1

            let next = current!
            let peekRaw = String(first) + (src.peekWhile { $0.isValidInNumeric })
            var peekNum = peekRaw.replacingOccurrences(of: String(.underscore), with: "")
            /// We must be immediately preceeded by a minus to flip the sign and only flip back if
            /// immediately preceeded by a const, tag or variable (which we assume will provide a
            /// numeric). Grammatical errors in the template (eg, keyword-numeric) may throw here
            if case .param(let p) = lexed[offset],
               case .operator(let op) = p, op == .minus {
                switch lexed[offset - 1] {
                    case .param(let p):
                        switch p {
                            case .literal,
                                 .function,
                                 .variable : sign = 1
                            case .operator : sign = -1
                            case .keyword  : throw badToken(.minus)
                        }
                    default: sign = -1
                }
            }

            switch (peekNum.contains(.period), next, peekNum.count > 2) {
                case (true, _, _) :                  testDouble = Double(peekNum)
                case (false, .binaryNotation, true): radix = 2
                case (false, .octalNotation, true):  radix = 8
                case (false, .hexNotation, true):    radix = 16
                default:                             testInt = Int(peekNum)
            }

            if let radix = radix {
                let start = peekNum.startIndex
                peekNum.removeSubrange(start ... peekNum.index(after: start))
                testInt = Int(peekNum, radix: radix)
            }

            if testInt != nil || testDouble != nil {
                // discard the minus if negative
                if sign == -1 { lexed.removeLast() }
                src.popWhile { $0.isValidInNumeric }
                if testInt != nil { return .param(.literal(.int(testInt! * sign))) }
                else { return .param(.literal(.double(testDouble! * Double(sign)))) }
            }
        }

        guard first.canStartIdentifier else { throw badToken(first) }
        /// At this point, just read the longest possible identifier-valid part (NO operators)
        let identifier = String(first) + src.readWhile { $0.isValidInIdentifier }
        
        /// If it's a keyword, return that
        if let kw = LeafKeyword(rawValue: identifier) { return .param(.keyword(kw)) }
        /// If identifier is followed by `(` it's a function or method call
        if current! == .leftParenthesis { return .param(.function(identifier)) }
        /// ... otherwise, a variable part
        else { return .param(.variable(identifier)) }
    }
    
    /// Signal whether whitespace should be retained (only needed currently for `[`)
    private var retainWhitespace: Bool { current == .leftBracket ? true : false }

    /// Convenience for making nested `LeafError->LexerError.unknownError`
    private func unknownError(_ reason: String) -> LeafError {
        err(.lexerError(.init(.unknownError(reason), src, lexed))) }
    /// Convenience for making nested `LeafError->LexerError.invalidParameterToken`
    private func badToken(_ character: Character) -> LeafError {
        err(.lexerError(.init(.invalidParameterToken(character), src, lexed))) }
    /// Convenience for making nested `LeafError->LexerError.badOperator`
    private func badOperator(_ op: LeafOperator) -> LeafError {
        err(.lexerError(.init(.invalidOperator(op), src, lexed))) }
    /// Convenience for making nested `LeafError->LexerError.untermindatedStringLiteral`
    private var unterminatedString: LeafError {
        err(.lexerError(.init(.unterminatedStringLiteral, src, lexed))) }
}
