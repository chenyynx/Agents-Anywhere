import Foundation

/// The runtime A/B switch for the collection timeline.
///
/// Default off: the existing SwiftUI `ScrollView` path stays the product
/// default until C6a flips it. `lastActiveKey` is written by the controller on
/// first appearance and shown in Settings, so a device test can prove the new
/// container actually ran instead of accepting the old path as green.
enum TimelineCollectionSwitch {
    static let key = "aa.timeline.collectionView"
    static let lastActiveKey = "aa.timeline.collectionViewLastActive"
}
