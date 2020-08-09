// MARK: Subject to change prior to 1.0.0 release
// MARK: -

/// `LeafCache` provides blind storage for compiled `LeafAST` objects.
///
/// The stored `LeafAST`s may or may not be fully renderable templates, and generally speaking no
/// attempts should be made inside a `LeafCache` adherent to make any changes to the stored document.
///
/// All definied access methods to a `LeafCache` adherent must guarantee `EventLoopFuture`-based
/// return values. For performance, an adherent may optionally provide additional, corresponding interfaces
/// where returns are direct values and not future-based by adhering to `SynchronousLeafCache` and
/// providing applicable option flags indicating which methods may be used. This should only used for
/// adherents where the cache store itself is not a bottleneck.
///
/// `LeafAST.name` is to be used in all cases as the key for retrieving cached documents.
public protocol LeafCache {
    /// Global setting for enabling or disabling the cache
    var isEnabled : Bool { get set }
    /// Current count of cached documents
    var count: Int { get }
    
    /// - Parameters:
    ///   - document: The `LeafAST` to store
    ///   - loop: `EventLoop` to return futures on
    ///   - replace: If a document with the same name is already cached, whether to replace or not.
    /// - Returns: The document provided as an identity return (or a failed future if it can't be inserted)
    func insert(_ document: Leaf4AST,
                on loop: EventLoop,
                replace: Bool) -> EventLoopFuture<Leaf4AST>
    
    /// - Parameters:
    ///   - key: `LeafAST.key`  to try to return
    ///   - loop: `EventLoop` to return futures on
    /// - Returns: `EventLoopFuture<LeafAST?>` holding the `LeafAST` or nil if no matching result
    func retrieve(_ key: Leaf4AST.Key,
                  on loop: EventLoop) -> EventLoopFuture<Leaf4AST?>

    /// - Parameters:
    ///   - key: `LeafAST.key`  to try to purge from the cache
    ///   - loop: `EventLoop` to return futures on
    /// - Returns: `EventLoopFuture<Bool?>` - If no document exists, returns nil. If removed,
    ///     returns true. If cache can't remove because of dependencies (not yet possible), returns false.
    func remove(_ key: Leaf4AST.Key,
                on loop: EventLoop) -> EventLoopFuture<Bool?>
    
    /// Touch a stored AST with an execution time
    func touch(_ key: Leaf4AST.Key,
               _ value: Leaf4AST.TouchValue)
}

/// A `LeafCache` that provides certain blocking methods for non-future access to the cache
///
/// Adherents *MUST* be thread-safe and *SHOULD NOT* be blocking simply to avoid futures -
/// only adhere to this protocol if using futures is needless overhead
internal protocol SynchronousLeafCache: LeafCache {    
    /// - Parameters:
    ///   - document: The `LeafAST` to store
    ///   - replace: If a document with the same name is already cached, whether to replace or not
    /// - Returns: The document provided as an identity return when success, or a failure error
    func insert(_ document: Leaf4AST, replace: Bool) -> Result<Leaf4AST, LeafError>
    
    /// - Parameter key: Name of the `LeafAST` to try to return
    /// - Returns: The requested `LeafAST` or nil if not found
    func retrieve(_ key: Leaf4AST.Key) -> Leaf4AST?
    
    /// - Parameter key: Name of the `LeafAST`  to try to purge from the cache
    /// - Returns: `Bool?` If removed,  returns true. If cache can't remove because of dependencies
    ///      (not yet possible), returns false. Nil if no such cached key exists.
    func remove(_ key: Leaf4AST.Key) -> Bool?
}
