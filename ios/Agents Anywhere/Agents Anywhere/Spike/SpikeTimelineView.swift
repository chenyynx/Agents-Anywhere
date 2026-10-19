import SwiftUI
import UIKit

// MARK: - Representable

struct SpikeTimelineView: UIViewControllerRepresentable {
    let model: SpikeModel

    func makeUIViewController(context: Context) -> SpikeCollectionController {
        SpikeCollectionController(model: model)
    }

    func updateUIViewController(_ controller: SpikeCollectionController, context: Context) {
        controller.sync()
    }
}

// MARK: - Hosting cell

final class SpikeHostingCell: UICollectionViewCell {
    static let reuseID = "SpikeHostingCell"

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(item: SpikeModel.Item, asyncParse: Bool) {
        contentConfiguration = UIHostingConfiguration {
            SpikeHostingRow(item: item, asyncParse: asyncParse)
                .id(item.id)
        }
        .margins(.all, 0)
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let size = contentView.systemLayoutSizeFitting(
            CGSize(width: layoutAttributes.frame.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        var attributes = layoutAttributes
        attributes.frame.size.height = ceil(size.height)
        return attributes
    }
}

private struct SpikeHostingRow: View {
    let item: SpikeModel.Item
    let asyncParse: Bool
    @State private var parsedLines: [String] = []

    private var lines: [String] {
        if !parsedLines.isEmpty { return parsedLines }
        if asyncParse { return ["…"] }
        return item.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: item.id) {
            guard asyncParse, parsedLines.isEmpty else { return }
            // Simulates ChatMarkdownView's detached parse: the first frame is
            // empty (placeholder), then the blocks arrive and the row grows.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            parsedLines = item.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
    }
}

// MARK: - Controller

@MainActor
final class SpikeCollectionController: UIViewController, UICollectionViewDelegate {
    let model: SpikeModel
    var collectionView: UICollectionView!
    var layout: SpikeTimelineLayout!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var itemsByID: [String: SpikeModel.Item] = [:]
    private var lastRevisions: [String: Int] = [:]
    var lastGeneration = -1
    private var lastScrollCommand = -1
    private var autoRunStarted = false
    var armedBottom = false

    init(model: SpikeModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        layout = SpikeTimelineLayout()
        layout.onTargetOffset = { [weak self] proposed, returned in
            self?.model.recordTarget(proposed: proposed, returned: returned)
        }
        layout.onPrepareForUpdates = { [weak self] in
            self?.model.recordPrepareForUpdates()
        }
        layout.onFinalizeUpdates = { [weak self] in
            self?.model.recordFinalizeUpdates()
        }
        layout.onInvalidationContext = { [weak self] delta in
            self?.model.recordInvalidationContext(delta: delta)
        }
        layout.onShouldInvalidate = { [weak self] in
            self?.model.recordShouldInvalidate()
        }
        layout.onAdjustment = { [weak self] delta in
            self?.model.recordAdjustment(delta: delta)
        }
        layout.onPinAdjustment = { [weak self] in
            self?.model.recordPinAdjustment()
        }

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        collectionView.register(SpikeHostingCell.self, forCellWithReuseIdentifier: SpikeHostingCell.reuseID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) {
            [weak self] collectionView, indexPath, id in
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: SpikeHostingCell.reuseID, for: indexPath
            ) as! SpikeHostingCell
            if let item = self?.itemsByID[id] {
                cell.configure(item: item, asyncParse: self?.model.asyncParseIDs.contains(id) ?? false)
            }
            return cell
        }

        sync()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !autoRunStarted,
              ProcessInfo.processInfo.arguments.contains(SpikeAutoRunner.launchArgument) else { return }
        autoRunStarted = true
        Task { @MainActor in
            await SpikeAutoRunner.run(on: self)
        }
    }

    // MARK: SwiftUI -> controller

    func sync() {
        guard isViewLoaded else { return }
        if lastGeneration != model.generation {
            applyItems()
        }
        if let command = model.scrollCommand, command.id != lastScrollCommand {
            lastScrollCommand = command.id
            performScroll(command.target)
        }
    }

    private func applyItems() {
        let oldIDs = layout.itemIDs
        let oldEstimates = layout.estimates
        let items = model.items
        let newIDs = items.map(\.id)
        let previousRevisions = lastRevisions

        let visibleFirst = collectionView.indexPathsForVisibleItems.min(by: { $0.item < $1.item })
        let anchorID = visibleFirst.flatMap { $0.item < oldIDs.count ? oldIDs[$0.item] : nil } ?? oldIDs.first
        let originOffset = max(-collectionView.adjustedContentInset.top, collectionView.contentOffset.y)
        let beforeY = anchorID.flatMap { id in
            oldIDs.firstIndex(of: id).map { layout.yOffset(of: $0, ids: oldIDs, estimates: oldEstimates) }
        }

        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        lastRevisions = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.revision) })
        lastGeneration = model.generation

        var estimates: [String: CGFloat] = [:]
        estimates.reserveCapacity(items.count)
        for item in items {
            estimates[item.id] = layout.estimate(for: item)
        }

        // Prepend detection: the old list is a suffix of the new one.
        if let anchorID, let beforeY,
           !oldIDs.isEmpty, newIDs.count > oldIDs.count,
           Array(newIDs.suffix(oldIDs.count)) == oldIDs {
            let newIndex = newIDs.firstIndex(of: anchorID) ?? 0
            let afterY = yOffset(of: newIndex, ids: newIDs, estimates: estimates)
            // Absolute target: the origin offset already carries the clamped
            // pull (max(-topInset, offsetY)), so the reader lands exactly where
            // the existing TimelineHistoryPosition expects.
            let target = originOffset + (afterY - beforeY)
            layout.setOwedTarget(target)
            model.recordOwedTarget(target)
            model.recordOwed(before: beforeY, after: afterY, owed: afterY - beforeY)
        } else {
            layout.setOwedTarget(nil)
            model.recordOwed(before: 0, after: 0, owed: 0)
        }

        layout.itemIDs = newIDs
        layout.estimates = estimates

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(newIDs)

        let changed = items.compactMap { item -> String? in
            guard let previous = previousRevisions[item.id] else { return nil }
            return previous != item.revision ? item.id : nil
        }
        if !changed.isEmpty {
            snapshot.reconfigureItems(changed)
            model.recordReconfigure(changed.count)
        }

        dataSource.apply(snapshot, animatingDifferences: false)
        model.recordContentHeight(collectionView.contentSize.height)
    }

    private func yOffset(of index: Int, ids: [String], estimates: [String: CGFloat]) -> CGFloat {
        var y: CGFloat = 0
        for offset in 0..<min(index, ids.count) {
            let id = ids[offset]
            y += (layout.measuredHeight(of: id) ?? estimates[id] ?? 200) + 8
        }
        return y
    }

    func setArmedBottom(_ value: Bool) {
        armedBottom = value
    }

    /// The real controller re-resolves the armed bottom target on every
    /// content-size change. The probe calls this explicitly after growth so the
    /// measurement is not confused with the layout's in-transaction pin.
    func repinIfArmed() {
        guard armedBottom, isViewLoaded,
              !collectionView.isTracking, !collectionView.isDecelerating else { return }
        let y = bottomOffset().y
        if abs(collectionView.contentOffset.y - y) > 0.5 {
            collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
    }

    func performScroll(_ target: SpikeModel.ScrollTarget) {
        let inset = collectionView.adjustedContentInset
        switch target {
        case .top:
            let y = -inset.top
            collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        case .bottomInstant:
            collectionView.setContentOffset(bottomOffset(), animated: false)
        case .bottomAnimated:
            collectionView.setContentOffset(bottomOffset(), animated: true)
        }
    }

    private func bottomOffset() -> CGPoint {
        let inset = collectionView.adjustedContentInset
        let maxY = max(-inset.top, collectionView.contentSize.height - collectionView.bounds.height + inset.bottom)
        return CGPoint(x: 0, y: maxY)
    }

    // MARK: UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        armedBottom = false
        model.recordDragStart(scrollView.contentSize.height)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        model.recordContentHeight(scrollView.contentSize.height)
        if scrollView.isTracking {
            model.recordDragDelta(scrollView.contentSize.height - model.dragStartHeight)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        model.recordDragDelta(scrollView.contentSize.height - model.dragStartHeight)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        model.recordDidEndScrollingAnimation()
    }
}
