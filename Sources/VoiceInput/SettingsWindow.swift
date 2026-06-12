import Cocoa

@MainActor
final class SettingsWindowController: NSWindowController {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton()
    private let deleteButton = NSButton()

    private let nameField = NSTextField()
    private let providerTypePopup = NSPopUpButton()
    private let baseURLField = NSTextField()
    private var apiKeyField: NSTextField = NSSecureTextField()
    private let modelField = NSTextField()
    private let showKeyButton = NSButton()
    private let testButton = NSButton()
    private let saveButton = NSButton()
    private let statusLabel = NSTextField()

    private var configs: [LLMConfig] = []
    private var editingIndex: Int? = nil
    private var testRefiner: LLMRefiner?
    private var isProgrammaticSelection = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "LLM Settings"
        window.center()
        super.init(window: window)
        setupUI()
        reloadData()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // Left side – list
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let selectedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("selected"))
        selectedCol.title = ""
        selectedCol.width = 32
        selectedCol.minWidth = 32
        selectedCol.maxWidth = 32
        tableView.addTableColumn(selectedCol)

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.width = 120
        nameCol.minWidth = 80
        tableView.addTableColumn(nameCol)

        let providerCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("provider"))
        providerCol.title = "Provider"
        providerCol.width = 80
        providerCol.minWidth = 60
        tableView.addTableColumn(providerCol)

        tableView.rowHeight = 28
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.selectionHighlightStyle = .regular
        scrollView.documentView = tableView

        addButton.bezelStyle = .roundRect
        addButton.title = "+"
        addButton.target = self
        addButton.action = #selector(addConfig)
        addButton.toolTip = "Add configuration"

        deleteButton.bezelStyle = .roundRect
        deleteButton.title = "-"
        deleteButton.target = self
        deleteButton.action = #selector(deleteConfig)
        deleteButton.toolTip = "Delete configuration"

        let leftButtonStack = NSStackView(views: [addButton, deleteButton])
        leftButtonStack.orientation = .horizontal
        leftButtonStack.spacing = 8

        let leftStack = NSStackView(views: [scrollView, leftButtonStack])
        leftStack.orientation = .vertical
        leftStack.spacing = 8
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        // Right side – form
        let rightStack = buildForm()
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        let split = NSStackView(views: [leftStack, rightStack])
        split.orientation = .horizontal
        split.spacing = 16
        split.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(split)

        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            split.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            split.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            split.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            leftStack.widthAnchor.constraint(equalToConstant: 210),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
    }

    private func buildForm() -> NSStackView {
        let grid = NSGridView()

        nameField.placeholderString = "My Config"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 340).isActive = true

        providerTypePopup.addItems(withTitles: ProviderType.allCases.map { $0.displayName })
        providerTypePopup.target = self
        providerTypePopup.action = #selector(providerTypeChanged)
        providerTypePopup.translatesAutoresizingMaskIntoConstraints = false
        providerTypePopup.widthAnchor.constraint(equalToConstant: 200).isActive = true

        baseURLField.placeholderString = ProviderType.openAICompatible.defaultBaseURL
        baseURLField.translatesAutoresizingMaskIntoConstraints = false
        baseURLField.widthAnchor.constraint(equalToConstant: 340).isActive = true

        apiKeyField.placeholderString = "sk-..."
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.widthAnchor.constraint(equalToConstant: 280).isActive = true

        showKeyButton.title = "Show"
        showKeyButton.bezelStyle = .roundRect
        showKeyButton.target = self
        showKeyButton.action = #selector(toggleShowKey)

        let keyStack = NSStackView(views: [apiKeyField, showKeyButton])
        keyStack.spacing = 8

        modelField.placeholderString = ProviderType.openAICompatible.defaultModel
        modelField.translatesAutoresizingMaskIntoConstraints = false
        modelField.widthAnchor.constraint(equalToConstant: 340).isActive = true

        grid.addRow(with: [NSTextField(labelWithString: "Name:"), nameField])
        grid.addRow(with: [NSTextField(labelWithString: "Provider:"), providerTypePopup])
        grid.addRow(with: [NSTextField(labelWithString: "API Base URL:"), baseURLField])
        grid.addRow(with: [NSTextField(labelWithString: "API Key:"), keyStack])
        grid.addRow(with: [NSTextField(labelWithString: "Model:"), modelField])

        testButton.title = "Test"
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testConnection)

        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveConfig)

        statusLabel.isEditable = false
        statusLabel.isBordered = false
        statusLabel.backgroundColor = .clear
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.maximumNumberOfLines = 2
        statusLabel.preferredMaxLayoutWidth = 360

        let buttonStack = NSStackView(views: [testButton, saveButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 12

        let vStack = NSStackView(views: [grid, buttonStack, statusLabel])
        vStack.orientation = .vertical
        vStack.spacing = 16
        vStack.alignment = .leading
        return vStack
    }

    // MARK: - Data

    private func reloadData() {
        configs = UserDefaults.standard.llmConfigs
        tableView.reloadData()
        if let selectedID = UserDefaults.standard.selectedConfigID,
           let idx = configs.firstIndex(where: { $0.id == selectedID }) {
            isProgrammaticSelection = true
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            isProgrammaticSelection = false
            loadForm(at: idx)
        } else if !configs.isEmpty {
            isProgrammaticSelection = true
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            isProgrammaticSelection = false
            loadForm(at: 0)
        } else {
            clearForm()
            editingIndex = nil
        }
    }

    private func loadForm(at index: Int) {
        guard configs.indices.contains(index) else { return }
        editingIndex = index
        let config = configs[index]
        nameField.stringValue = config.name
        baseURLField.stringValue = config.baseURL
        apiKeyField.stringValue = config.apiKey
        modelField.stringValue = config.model

        if let popupIndex = ProviderType.allCases.firstIndex(of: config.providerType) {
            providerTypePopup.selectItem(at: popupIndex)
        }
        updatePlaceholders()

        statusLabel.stringValue = ""
    }

    private func clearForm() {
        nameField.stringValue = ""
        baseURLField.stringValue = ""
        apiKeyField.stringValue = ""
        modelField.stringValue = ""
        providerTypePopup.selectItem(at: 0)
        updatePlaceholders()
        statusLabel.stringValue = ""
        editingIndex = nil
    }

    private func currentProviderType() -> ProviderType {
        let index = providerTypePopup.indexOfSelectedItem
        guard index >= 0, index < ProviderType.allCases.count else { return .openAICompatible }
        return ProviderType.allCases[index]
    }

    private func updatePlaceholders() {
        let provider = currentProviderType()
        baseURLField.placeholderString = provider.defaultBaseURL
        modelField.placeholderString = provider.defaultModel
        if provider == .ollama {
            apiKeyField.placeholderString = "(optional)"
        } else {
            apiKeyField.placeholderString = "sk-..."
        }
    }

    // MARK: - Actions

    @objc private func providerTypeChanged() {
        updatePlaceholders()
    }

    @objc private func addConfig() {
        let newConfig = LLMConfig(
            id: UUID(),
            name: "New Config",
            providerType: .openAICompatible,
            baseURL: "",
            apiKey: "",
            model: ""
        )
        configs.append(newConfig)
        UserDefaults.standard.llmConfigs = configs
        tableView.reloadData()
        let newIndex = configs.count - 1
        tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
        loadForm(at: newIndex)
        UserDefaults.standard.selectedConfigID = newConfig.id
    }

    @objc private func deleteConfig() {
        let row = tableView.selectedRow
        guard row >= 0 && row < configs.count else { return }
        configs.remove(at: row)
        UserDefaults.standard.llmConfigs = configs
        if configs.isEmpty {
            UserDefaults.standard.selectedConfigID = nil
        } else if row < configs.count {
            UserDefaults.standard.selectedConfigID = configs[row].id
        } else if !configs.isEmpty {
            UserDefaults.standard.selectedConfigID = configs[configs.count - 1].id
        }
        reloadData()
    }

    @objc private func saveConfig() {
        let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let name = trimmedName.isEmpty ? "Untitled" : trimmedName
        let provider = currentProviderType()
        let baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespaces)
        let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespaces)
        let model = modelField.stringValue.trimmingCharacters(in: .whitespaces)
        let finalModel = model.isEmpty ? provider.defaultModel : model

        if let index = editingIndex, configs.indices.contains(index) {
            configs[index].name = name
            configs[index].providerType = provider
            configs[index].baseURL = baseURL
            configs[index].apiKey = apiKey
            configs[index].model = finalModel
            UserDefaults.standard.llmConfigs = configs
            UserDefaults.standard.selectedConfigID = configs[index].id
            reloadData()
        } else {
            let newConfig = LLMConfig(
                id: UUID(),
                name: name,
                providerType: provider,
                baseURL: baseURL,
                apiKey: apiKey,
                model: finalModel
            )
            configs.append(newConfig)
            UserDefaults.standard.llmConfigs = configs
            UserDefaults.standard.selectedConfigID = newConfig.id
            reloadData()
        }

        statusLabel.stringValue = "Saved!"
        statusLabel.textColor = .systemGreen
    }

    @objc private func toggleShowKey() {
        let currentValue = apiKeyField.stringValue
        let parent = apiKeyField.superview
        apiKeyField.removeFromSuperview()

        if apiKeyField is NSSecureTextField {
            let plain = NSTextField()
            plain.stringValue = currentValue
            plain.placeholderString = apiKeyField.placeholderString ?? "sk-..."
            plain.translatesAutoresizingMaskIntoConstraints = false
            plain.widthAnchor.constraint(equalToConstant: 280).isActive = true
            apiKeyField = plain
            showKeyButton.title = "Hide"
        } else {
            let secure = NSSecureTextField()
            secure.stringValue = currentValue
            secure.placeholderString = apiKeyField.placeholderString ?? "sk-..."
            secure.translatesAutoresizingMaskIntoConstraints = false
            secure.widthAnchor.constraint(equalToConstant: 280).isActive = true
            apiKeyField = secure
            showKeyButton.title = "Show"
        }

        if let parent = parent as? NSStackView {
            parent.insertView(apiKeyField, at: 0, in: .leading)
        }
    }

    @objc private func testConnection() {
        statusLabel.stringValue = "Testing..."
        statusLabel.textColor = .secondaryLabelColor

        let config = LLMConfig(
            id: UUID(),
            name: "Test",
            providerType: currentProviderType(),
            baseURL: baseURLField.stringValue.trimmingCharacters(in: .whitespaces),
            apiKey: apiKeyField.stringValue.trimmingCharacters(in: .whitespaces),
            model: modelField.stringValue.trimmingCharacters(in: .whitespaces)
        )

        testRefiner = LLMRefiner(config: config)
        testRefiner?.delegate = self
        testRefiner?.refine(text: "hello")
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return configs.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard configs.indices.contains(row) else { return nil }
        let config = configs[row]
        let selectedID = UserDefaults.standard.selectedConfigID
        switch tableColumn?.identifier.rawValue {
        case "selected":
            return config.id == selectedID ? "✅" : ""
        case "provider":
            return config.providerType.displayName
        default:
            return config.name
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }
        let row = tableView.selectedRow
        if row >= 0 && row < configs.count {
            loadForm(at: row)
            UserDefaults.standard.selectedConfigID = configs[row].id
            tableView.reloadData()
        } else {
            clearForm()
        }
    }
}

// MARK: - LLMRefinerDelegate

extension SettingsWindowController: LLMRefinerDelegate {
    func llmRefinerDidStart(_ refiner: LLMRefiner) {}

    func llmRefiner(_ refiner: LLMRefiner, didFinishWith text: String) {
        statusLabel.stringValue = "Success! Response: \(text)"
        statusLabel.textColor = .systemGreen
        testRefiner = nil
    }

    func llmRefiner(_ refiner: LLMRefiner, didFailWith error: Error) {
        statusLabel.stringValue = "Failed: \(error.localizedDescription)"
        statusLabel.textColor = .systemRed
        testRefiner = nil
    }
}
