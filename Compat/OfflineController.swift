import UIKit

final class OfflineController: UITableViewController {
    var chats: [CachedChat] = []
    var openOnline: ((String) -> Void)?
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "离线聊天"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(close))
        let label = UILabel()
        label.text = "最近 20 个聊天 · 7 天内已加载的文字\n离线副本可能不完整，不包含图片和附件。"
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        label.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 72)
        tableView.tableHeaderView = label
        if chats.isEmpty {
            let empty = UILabel()
            empty.text = "还没有离线聊天\n联网打开一个聊天后，会自动保存已加载的文字。"
            empty.numberOfLines = 0; empty.textAlignment = .center; empty.textColor = .secondaryLabel
            tableView.backgroundView = empty
        }
    }
    @objc private func close() { dismiss(animated: true) }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { chats.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chat") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "chat")
        let chat = chats[indexPath.row]
        cell.textLabel?.text = chat.title
        cell.textLabel?.numberOfLines = 2
        cell.detailTextLabel?.text = DateFormatter.localizedString(from: chat.savedAt, dateStyle: .short, timeStyle: .short)
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let reader = OfflineReader()
        reader.chat = chats[indexPath.row]
        reader.openOnline = openOnline
        navigationController?.pushViewController(reader, animated: true)
    }
}
final class OfflineReader: UIViewController {
    var chat: CachedChat!
    var openOnline: ((String) -> Void)?
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "离线副本"
        let text = UITextView()
        text.isEditable = false
        text.adjustsFontForContentSizeCategory = true
        text.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 32, right: 16)
        text.font = .preferredFont(forTextStyle: .body)
        text.backgroundColor = .systemBackground
        text.text = "离线副本 · " + DateFormatter.localizedString(from: chat.savedAt, dateStyle: .medium, timeStyle: .short) + "\n仅保存已加载文字，可能不完整。\n\n" + chat.messages.map { ($0.role == "user" ? "你" : "ChatGPT") + "\n" + $0.text }.joined(separator: "\n\n────────\n\n")
        view = text
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "在线打开", style: .plain, target: self, action: #selector(open))
    }
    @objc private func open() {
        let id = chat.id
        let action = openOnline
        dismiss(animated: true) { action?(id) }
    }
}
