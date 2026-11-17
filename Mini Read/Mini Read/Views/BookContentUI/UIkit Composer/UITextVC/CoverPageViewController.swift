import UIKit

// MARK: - 扉页（封面 + 书名 + 作者）

/// 扉页：全书第一章被判定为版权页时，自动生成的开篇第一页。
///
/// 一本书的开篇结构由此变成（与纸质书一致）：
/// ```
///   扉页（本类：封面 + 书名 + 作者）
///   → 版权页（TextVC + ChapterTypography.copyrightString）
///   → 正文第一章（页码从 1 开始，见 ViewController.globalPageNumber）
/// ```
///
/// 设计原则（参照 Apple Books 的内容优先，不复制其界面）：
/// - **纸面、墨色、字体全部跟随当前阅读设置**——换纸面/换字体即时生效，
///   前置页与正文不会割裂；
/// - 封面按版心比例（宽 ≤ 页宽 58%、高 ≤ 页高 50%）居中偏上，竖长图
///   不会把书名挤出屏幕；等比缩放，绝不变形；
/// - 书名用阅读字体加大加粗（字体无粗体字重时只用字号分层），
///   作者小一档、辅助墨色——层次靠字号与墨色，不靠装饰；
/// - **没有封面图时不画占位框**：纯文字扉页（书名居中放大）同样体面。
///   EPUB 元数据缺失时一个尴尬的空框比没有框更糟；
/// - 所有尺寸约束走乘数锚点（相对页面边长），不依赖 viewDidLoad 时的
///   bounds——UIPageViewController 子 VC 的装载时机不保证 bounds 已定。
final class CoverPageViewController: UIViewController {

    // MARK: - Properties

    private let background: ReadingBackground
    private let settings: AppSettings
    /// 与正文分页共用的有效边距（极端边距会被收缩）。
    private let margins: ReaderMargins
    private let bookTitle: String
    private let bookAuthor: String
    private let coverImageURL: URL?

    private weak var coverImageView: UIImageView?
    private weak var titleLabel: UILabel?
    private weak var authorLabel: UILabel?

    // MARK: - Init

    init(background: ReadingBackground,
         settings: AppSettings,
         margins: ReaderMargins,
         title: String,
         author: String,
         coverImageURL: URL?) {
        self.background    = background
        self.settings      = settings
        self.margins       = margins
        self.bookTitle     = title
        self.bookAuthor    = author
        self.coverImageURL = coverImageURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupBackground()
        let hasCover = setupCoverImage()
        setupLabels(hasCoverImage: hasCover)
        setupAccessibility()
    }

    // MARK: - Background

    /// 与正文页/空白页共用同一张纸面：pageCurl 转场会把相邻页合到同一层，
    /// 纸面不一致会在书脊处露馅（见 PageBackgroundView 注释）。
    private func setupBackground() {
        PageBackgroundView.install(in: view, background: background)
    }

    // MARK: - Cover Image

    /// 布局封面图。返回是否真的有图上屏（决定文字部分的排版形态）。
    @discardableResult
    private func setupCoverImage() -> Bool {
        guard let url = coverImageURL,
              let image = UIImage(contentsOfFile: url.path),
              image.size.width > 0, image.size.height > 0
        else { return false }

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        coverImageView = imageView

        let marginLeft  = margins.left
        let marginRight = margins.right
        let marginTop   = margins.top
        // 高宽比（高/宽），用于把高度钉在宽度上
        let aspect = image.size.height / image.size.width

        NSLayoutConstraint.activate([
            // 宽：默认页宽的 58%；版心更窄时以版心为准（0.58 那条降级让位）
            imageView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.58)
                .withPriority(.defaultHigh),
            imageView.widthAnchor.constraint(
                lessThanOrEqualTo: view.widthAnchor,
                multiplier: 1.0,
                constant: -(marginLeft + marginRight)
            ),
            // 高：跟随宽度等比；最高不超过半页（竖长图把文字挤出屏的保险）
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: aspect)
                .withPriority(.defaultHigh),
            imageView.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.5),

            imageView.topAnchor.constraint(equalTo: view.topAnchor, constant: marginTop),
            imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        return true
    }

    // MARK: - Labels

    private func setupLabels(hasCoverImage: Bool) {
        let trimmedTitle = bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthor = bookAuthor.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedTitle.isEmpty {
            titleLabel = makeLabel(
                text: trimmedTitle,
                // 无封面时书名放大到 1.8 倍（纯文字扉页）；有封面时 1.3 倍
                size: CGFloat(settings.fontSize) * (hasCoverImage ? 1.3 : 1.8),
                bold: true,
                color: background.textTone.inkColor
            )
        }
        if !trimmedAuthor.isEmpty {
            authorLabel = makeLabel(
                text: trimmedAuthor,
                size: CGFloat(settings.fontSize),
                bold: false,
                color: background.textTone.secondaryInkColor
            )
        }

        // 垂直锚点：有封面时挂在封面下方；无封面时落在「天头」处
        // （三倍上边距，纯文字扉页的经典位置）。
        let titleTopAnchor: NSLayoutYAxisAnchor
        let titleTopConstant: CGFloat
        if hasCoverImage, let cover = coverImageView {
            titleTopAnchor = cover.bottomAnchor
            titleTopConstant = 0
        } else {
            titleTopAnchor = view.topAnchor
            titleTopConstant = margins.top * 3
        }

        if let title = titleLabel {
            view.addSubview(title)
            NSLayoutConstraint.activate([
                title.topAnchor.constraint(equalTo: titleTopAnchor, constant: titleTopConstant),
                title.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                title.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 1.0,
                                             constant: -(margins.left + margins.right)),
            ])
        }
        if let author = authorLabel {
            view.addSubview(author)
            NSLayoutConstraint.activate([
                author.topAnchor.constraint(
                    equalTo: titleLabel?.bottomAnchor ?? view.topAnchor,
                    constant: titleLabel != nil ? CGFloat(settings.fontSize) * 0.6 : titleTopConstant
                ),
                author.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                author.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 1.0,
                                              constant: -(margins.left + margins.right)),
            ])
        }
    }

    private func makeLabel(text: String, size: CGFloat, bold: Bool, color: UIColor) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.textAlignment = .center
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textColor = color
        label.font = resolvedFont(ofSize: size, bold: bold)
        return label
    }

    /// 扉页用字：跟随阅读字体；加粗失败（单一字重字体，如霞鹜文楷）时
    /// 不强求，字号分层已经足够（同 ChapterTypography.headingAttributes）。
    private func resolvedFont(ofSize size: CGFloat, bold: Bool) -> UIFont {
        let base = resolveReadingUIFont(settings.fontFamily, size: size)
        guard bold, let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    // MARK: - Accessibility

    /// 扉页的 VoiceOver 顺序：封面图（播报「《书名》封面」）→ 书名 → 作者。
    /// 显式指定顺序，不依赖系统按视图层级猜。
    private func setupAccessibility() {
        let image = coverImageView
        image?.isAccessibilityElement = true
        image?.accessibilityLabel = "《\(bookTitle)》封面"
        image?.accessibilityTraits = .image

        view.accessibilityElements = [image, titleLabel, authorLabel].compactMap { $0 }
    }
}

// MARK: - Constraint Priority Helper

private extension NSLayoutConstraint {
    /// 链式设置优先级，让约束表读起来像声明。
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
