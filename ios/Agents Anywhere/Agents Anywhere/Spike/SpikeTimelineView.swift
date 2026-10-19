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

// MARK: - Cell

final class SpikeCell: UICollectionViewCell {
    static let reuseID = "SpikeCell"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 8
        contentView.clipsToBounds = true
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ item: SpikeModel.Item) {
        label.text = item.text
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

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        collectionView.register(SpikeCell.self, forCellWithReuseIdentifier: SpikeCell.reuseID)
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
                withReuseIdentifier: SpikeCell.reuseID, for: indexPath
            ) as! SpikeCell
            if let item = self?.itemsByID[id] {
                cell.configure(item)
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
        let items = model.items
        let newIDs = items.map(\.id)
        let previousRevisions = lastRevisions

        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        lastRevisions = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.revision) })
        lastGeneration = model.generation

        var estimates: [String: CGFloat] = [:]
        estimates.reserveCapacity(items.count)
        for item in items {
            estimates[item.id] = layout.estimate(for: item)
        }

        // Prepend detection: the old list is a suffix of the new one.
        if !oldIDs.isEmpty, newIDs.count > oldIDs.count, Array(newIDs.suffix(oldIDs.count)) == oldIDs {
            let anchorID = oldIDs[0]
            let beforeY = layout.yOffset(of: 0, ids: oldIDs, estimates: layout.estimates)
            let newIndex = newIDs.firstIndex(of: anchorID) ?? 0
            let afterY = layout.yOffset(of: newIndex, ids: newIDs, estimates: estimates)
            layout.anchorID = anchorID
            layout.owed = afterY - beforeY
            model.recordOwed(before: beforeY, after: afterY, owed: afterY - beforeY)
        } else {
            layout.anchorID = nil
            layout.owed = 0
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
