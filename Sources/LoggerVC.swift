//
//  LoggerVC.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/3/21.
//  Copyright © 2017年 LawLincoln. All rights reserved.
//
#if os(iOS)
    import UIKit
    import MessageUI
    #if !PACKING_FOR_APPSTORE
        import LuooPersistence
        import SystemEnhancement
    #endif
    
    public final class FPLoggerVC: UIViewController {
        
        fileprivate lazy var _switchGroup: UIView = {
            let h = CGFloat(44)
            let w = UIScreen.main.bounds.width
            let wrap = UIView(frame: CGRect(x: 0, y: 64, width: w, height: h))
            wrap.backgroundColor = .white
            let label = UILabel(frame: CGRect(x: 20, y: 0, width: 200, height: h))
            label.opaqueMe()
            label.font = UIFont.luooFont(of: 18, weight: .thin)
            label.textAlignment = .left
            label.text = "📝保存打印记录到磁盘"
            label.sizeToFit()
            label.frame.origin.y = (h - label.frame.height) / 2
            let x = w - 51 - 20
            let swi = UISwitch(frame: CGRect(x: x, y: 6.5, width: 51, height: 31))
            swi.addTarget(self, action: #selector(FPLoggerVC.switchChange(sender:)), for: .valueChanged)
            swi.isOn = FPLogger.shared.logToFile
            wrap.addSubview(label)
            wrap.addSubview(swi)
            wrap.layer.addSeperator(0, isBottom: true)
            return wrap
        }()
        
        @objc private func switchChange(sender: UISwitch) {
            FPLogger.shared.logToFile = sender.isOn
        }
        
        fileprivate lazy var _logFolder: UIView = {
            let h = CGFloat(44)
            let w = UIScreen.main.bounds.width
            let wrap = UIView(frame: CGRect(x: 0, y: 64 + 44, width: w, height: h))
            wrap.backgroundColor = .white
            let label = UILabel(frame: CGRect(x: 20, y: 0, width: 200, height: h))
            label.opaqueMe()
            label.font = UIFont.luooFont(of: 18, weight: .thin)
            label.textAlignment = .left
            label.text = "📁打印文件"
            label.sizeToFit()
            label.frame.origin.y = (h - label.frame.height) / 2
            
            let swi = UILabel(frame: CGRect(x: 0, y: 0, width: 200, height: h))
            swi.opaqueMe()
            swi.font = UIFont.luooFont(of: 30, weight: .thin)
            swi.textAlignment = .left
            swi.text = ">"
            swi.sizeToFit()
            swi.frame.origin.y = (h - swi.frame.height) / 2
            swi.frame.origin.x = w - swi.frame.width - 20
            wrap.addSubview(label)
            wrap.addSubview(swi)
            wrap.layer.addSeperator(0, isBottom: true)
            let tap = UITapGestureRecognizer(target: self, action: #selector(FPLoggerVC.showFolder))
            wrap.addGestureRecognizer(tap)
            return wrap
        }()
        
        @objc private func showFolder() {
            let vc = LogFilerListVC()
            show(vc, sender: nil)
        }
        
        
        fileprivate lazy var _segment: UISegmentedControl = {
            let all: [FPLogger.Module] = [.audioQueue, .audioStream, .httpStream, .fileStream, .cachingStream, .freePlayer, .id3Parser]
            let items = all.map({$0.symbolize}) + ["全部"]
            let seg = UISegmentedControl(items: items)
            seg.frame = CGRect(x: 20, y: 64 + 44 + 44 + 10, width: UIScreen.main.bounds.width - 40, height: 30)
            seg.addTarget(self, action:  #selector(FPLoggerVC.segChange(sender:)), for: .valueChanged)
            seg.selectedSegmentIndex = 7
            return seg
        }()

        @objc private func segChange(sender: UISegmentedControl) {
            var modules: Set<FPLogger.Module> = []
            switch sender.selectedSegmentIndex {
            case 0: modules.insert(.audioQueue)
            case 1: modules.insert(.audioStream)
            case 2: modules.insert(.httpStream)
            case 3: modules.insert(.fileStream)
            case 4: modules.insert(.cachingStream)
            case 5: modules.insert(.freePlayer)
            case 6: modules.insert(.id3Parser)
            case 7: modules = FPLogger.Module.All
            default: break
            }
            FPLogger.disable()
            FPLogger.enable(modules: modules)
            _textView.lines(filter: modules.count > 1 ? nil : modules.first)
        }
        
        
        private lazy var _textView: LogTextView = {
            let tv = LogTextView(fileName: FPLogger.shared.logfile, initialize: FPLogger.shared.lastRead)
            tv.frame = UIScreen.main.bounds
            let y = self._segment.frame.maxY + 10
            let h = UIScreen.main.bounds.height - y - 10
            let x = CGFloat(20)
            let w = self._segment.frame.width
            tv.frame = CGRect(x: x, y: y, width: w, height: h)
            tv.backgroundColor = UIColor.darkGray
            return tv
        }()
        
        deinit {
            FPLogger.disable()
        }
        
        required public init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
        }
        
        override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
            super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        }
        
        convenience public init() {
            self.init(nibName: nil, bundle: nil)
            initialize()
        }
        
        
        private func initialize() {
            FPLogger.enable()
        }
        
      
        
        public override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .white
            view.addSubview(_switchGroup)
            view.addSubview(_logFolder)
            view.addSubview(_segment)
            view.addSubview(_textView)
            navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: UIBarButtonSystemItem.cancel, target: self, action: #selector(FPLoggerVC._dismiss))
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: UIView())
            navigationItem.title = "播放器监视器"
        }
        
        @objc private func _dismiss() {
            dismiss(animated: true, completion: nil)
        }
    }
    
    extension FPLoggerVC {
        public static func show() {
            let logger = FPLoggerVC()
            let navi = UINavigationController(rootViewController: logger)
            navi.view.backgroundColor = .white
            UIApplication.showDetail(navi)
        }
        
        public func dismiss() {
            dismiss(animated: true, completion: nil)
        }
    }
    
    // MARK: - LogFilerListVC
    private final class LogFilerListVC: UITableViewController {
        fileprivate var _list: [String] = []
        override init(style: UITableViewStyle) {
            super.init(style: style)
        }
        
        required init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
        }
        
        override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
            super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        }
        
        convenience init() {
            self.init(nibName: nil, bundle: nil)
            initialize()
        }
        
        private func initialize() {
            navigationItem.title = "列表"
            tableView.delegate = self
            tableView.dataSource = self
            tableView.register(UITableViewCell.self, forCellReuseIdentifier: UITableViewCell.identifier)
            load()
        }
        
        private func load() {
            DispatchQueue.global(qos: .userInitiated).async {
                let folder = FPLogger.shared.logFolder
                let fs = FileManager.default
                do {
                    let contents = try fs.contentsOfDirectory(atPath: folder).filter({ (item) -> Bool in
                        if item == ".DS_Store" { return false }
                        return true
                    })
                    DispatchQueue.main.async {
                        self._list = contents
                        self.tableView.reloadData()
                    }
                } catch { }
            }
        }
        
        override func viewDidLoad() {
            super.viewDidLoad()
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(LogFilerListVC.clean))
        }
        
        @objc private func clean() {
            if _list.count == 0 { return }
            let alert = UIAlertController(title: "⚠️", message: "清楚所有播放器记录文件", preferredStyle: .alert)
            let delete = UIAlertAction(title: "删除", style: .destructive, handler: {[weak self] (_) in
                FPLogger.cleanAllLog()
                self?.load()
            })
            let cancel = UIAlertAction(title: "放弃", style: .default, handler: nil)
            alert.addAction(delete)
            alert.addAction(cancel)
            showDetailViewController(alert, sender: nil)
        }
        
        override func numberOfSections(in tableView: UITableView) -> Int {
            return 1
        }
        
        override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            return _list.count
        }
        
        override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: UITableViewCell.identifier)!
            cell.textLabel?.text = _list[safe: indexPath.row]
            return cell
        }
        
        override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCellEditingStyle, forRowAt indexPath: IndexPath) {
            if editingStyle == .delete {
                DispatchQueue.global(qos: .userInitiated).async {
                    let folder = FPLogger.shared.logFolder
                    let fs = FileManager.default
                    do {
                        let toDelete = self._list[indexPath.row]
                        let path = (folder as NSString).appendingPathComponent(toDelete)
                        try fs.removeItem(atPath: path)
                    } catch { }
                    DispatchQueue.main.async {
                        tableView.beginUpdates()
                        self._list.remove(at: indexPath.row)
                        tableView.deleteRows(at: [indexPath], with: .automatic)
                        tableView.endUpdates()
                    }
                }
            }
        }
        
        override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
            return true
        }
        
        override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)
            guard let target = _list[safe: indexPath.row] else { return }
            let vc = LogFileDetail(name: target)
            show(vc, sender: nil)
        }
    }
    
    
    // MARK: - LogFileDetail View Controller
    private final class LogFileDetail: UIViewController, MFMailComposeViewControllerDelegate {
        
        fileprivate lazy var _segment: UISegmentedControl = {
            let all: [FPLogger.Module] = [.audioQueue, .audioStream, .httpStream, .fileStream, .cachingStream, .freePlayer, .id3Parser]
            let items = all.map({$0.symbolize}) + ["全部"]
            let seg = UISegmentedControl(items: items)
            seg.addTarget(self, action:  #selector(LogFileDetail.segChange(sender:)), for: .valueChanged)
            seg.selectedSegmentIndex = 7
            seg.backgroundColor = .white
            return seg
        }()
        
        @objc private func segChange(sender: UISegmentedControl) {
            var filter: FPLogger.Module?
            switch sender.selectedSegmentIndex {
            case 0: filter = FPLogger.Module.audioQueue
            case 1: filter = FPLogger.Module.audioStream
            case 2: filter = FPLogger.Module.httpStream
            case 3: filter = FPLogger.Module.fileStream
            case 4: filter = FPLogger.Module.cachingStream
            case 5: filter = FPLogger.Module.freePlayer
            case 6: filter = FPLogger.Module.id3Parser
            default: break
            }
            _textView?.lines(filter: filter)
        }
        
        private var _textView: LogTextView?
        private var _file: String = ""
        
        required public init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
        }
        
        override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
            super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        }
        
        
        convenience public init(name: String) {
            self.init(nibName: nil, bundle: nil)
            _file = FPLogger.shared.logFolder + "/" + name
            let tv = LogTextView(fileName: _file, initialize: 0)
            tv.frame = UIScreen.main.bounds
            _textView = tv
            view.addSubview(tv)
            tv.translatesAutoresizingMaskIntoConstraints = false
            let c = NSLayoutConstraint.constraints(withVisualFormat: "H:|-0-[_textView]-0-|", options: NSLayoutFormatOptions.alignAllLeft, metrics: nil, views: ["_textView" : tv])
            let b = NSLayoutConstraint.constraints(withVisualFormat: "V:|-64-[_textView]-0-|", options: NSLayoutFormatOptions.alignAllLeft, metrics: nil, views: ["_textView" : tv])
            view.addConstraints(c)
            view.addConstraints(b)
        }
        
        override func viewDidLoad() {
            super.viewDidLoad()
            automaticallyAdjustsScrollViewInsets = false
            view.backgroundColor = .white
            navigationItem.titleView = _segment
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .compose, target: self, action: #selector(LogFileDetail.sendEmailButtonTapped))
        }
        
        @objc private func sendEmailButtonTapped() {
            let mailComposeViewController = configuredMailComposeViewController()
            if MFMailComposeViewController.canSendMail() {
                self.present(mailComposeViewController, animated: true, completion: nil)
            } else {
                self.showSendMailErrorAlert()
            }
        }
        
        private func configuredMailComposeViewController() -> MFMailComposeViewController {
            let mailComposerVC = MFMailComposeViewController()
            mailComposerVC.mailComposeDelegate = self // Extremely important to set the --mailComposeDelegate-- property, NOT the --delegate-- property
            
            mailComposerVC.setToRecipients(["appsupport@luoo.net"])
            mailComposerVC.setSubject("播放器记录文件")
            mailComposerVC.setMessageBody("请描述你遇到的问题，我们将会在记录文件里面查找", isHTML: false)
            
            let url = URL(fileURLWithPath: _file)
            if let data = try? Data(contentsOf: url) {
                mailComposerVC.addAttachmentData(data, mimeType: "text/plain", fileName: url.lastPathComponent)
            }
            
            return mailComposerVC
        }
        
        private func showSendMailErrorAlert() {
            let sendMailErrorAlert = UIAlertView(title: "发送失败", message: "该设备发送不了e-mail. 请检查设置", delegate: self, cancelButtonTitle: "好的")
            sendMailErrorAlert.show()
        }
        
        // MARK: MFMailComposeViewControllerDelegate Method
        fileprivate func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true, completion: nil)
        }
    }
    
    // MARK: - LogTextView
    private final class LogTextView: UIView, UITextFieldDelegate {
        
        private var _file: UnsafeMutablePointer<FILE>?
        private var _filter: FPLogger.Module?
        private var _total = ""
        private var _timer: DispatchSourceTimer?
        private var _monitorQueue = DispatchQueue(label: "com.selfstudio.freeplayer.logTextView")
        private var _lastReadPosition = UInt64()
        private var _filterText: String?
        private lazy var _textView: UITextView = {
            let tv = UITextView()
            tv.isEditable = false
            tv.font = UIFont.luooFont(of: 11, weight: .thin)
            tv.textColor = UIColor.white
            tv.backgroundColor = .darkGray
            return tv
        }()
        private lazy var _filterTextInput: UITextField = {
            let tf = UITextField(frame: .zero)
            tf.delegate = self
            tf.backgroundColor = .white
            tf.keyboardAppearance = .dark
            tf.returnKeyType = .search
            tf.placeholder = "关键字过滤"
            tf.font = UIFont.luooFont(of: 16, weight: .light)
            tf.textAlignment = .center
            tf.borderStyle = .roundedRect
            tf.clearButtonMode = .whileEditing
            return tf
        }()
        private lazy var _dragDetchView: UIView = {
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 20, height: 0))
            view.backgroundColor = UIColor.lightGray.withAlphaComponent(0.3)
            let dragGesture = UIPanGestureRecognizer(target: self, action: #selector(LogTextView.drag(sender:)))
            view.addGestureRecognizer(dragGesture)
            return view
        }()
        
        @objc private func drag(sender: UIPanGestureRecognizer) {
            let y = sender.location(in: _dragDetchView).y
            let percent = y / (_dragDetchView.frame.height - 60)
            var pointY = ceil(_textView.contentSize.height * percent)
            let max = _textView.contentSize.height + _textView.frame.height
            if pointY > max { pointY = max }
            _textView.setContentOffset(CGPoint(x: 0, y: pointY), animated: false)
        }
        
        deinit {
            guard let f = _file else { return }
            fclose(f)
        }
        required init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
        }
        
        convenience init(fileName: String, initialize position: UInt64 = 0) {
            self.init(frame: .zero)
            backgroundColor = .darkGray
            let fname = fileName.withCString({$0})
            if access(fname, F_OK) != -1 { // file exists
                _file = fopen(fname, "r".withCString({$0}))
                _lastReadPosition = position
                loopRead()
            }
            _textView.translatesAutoresizingMaskIntoConstraints = false
            _filterTextInput.translatesAutoresizingMaskIntoConstraints = false
            _dragDetchView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(_textView)
            addSubview(_filterTextInput)
            addSubview(_dragDetchView)
            
            let a = NSLayoutConstraint.constraints(withVisualFormat: "H:|-0-[_textView]-0-|", options: NSLayoutFormatOptions.alignAllLeft, metrics: nil, views: ["_textView" : _textView])
            let b = NSLayoutConstraint.constraints(withVisualFormat: "V:|-0-[_filterTextInput(\(30))]-0-[_textView]-0-|", options: NSLayoutFormatOptions.alignAllLeft, metrics: nil, views: ["_textView" : _textView, "_filterTextInput" : _filterTextInput])
            let c = NSLayoutConstraint.constraints(withVisualFormat: "H:|-0-[_filterTextInput]-0-|", options: NSLayoutFormatOptions.alignAllLeft, metrics: nil, views: ["_filterTextInput" : _filterTextInput])
            let d = NSLayoutConstraint.constraints(withVisualFormat: "H:[_dragDetchView(18)]-0-|", options: NSLayoutFormatOptions.alignAllLeft, metrics: nil, views: ["_dragDetchView" : _dragDetchView])
            let f = NSLayoutConstraint.constraints(withVisualFormat: "V:|-0-[_dragDetchView]-0-|", options: NSLayoutFormatOptions.alignAllLeft, metrics: nil, views: ["_dragDetchView" : _dragDetchView])
            addConstraints(a)
            addConstraints(b)
            addConstraints(c)
            addConstraints(d)
            addConstraints(f)
        }
        
        
        public func lines(filter: FPLogger.Module? = nil) {
            _filter = filter
            DispatchQueue.global(qos: .userInitiated).async {
                let lines = self._total.components(separatedBy: FPLogger.lineSeperator)
                if let f = filter {
                    let module = f.symbolize
                    let content = lines.filter({ (line) -> Bool in
                        var has = line.hasPrefix(module) || line.hasPrefix("🎹")
                        if let keyword = self._filterText?.lowercased(), has {
                            has = line.lowercased().contains(keyword)
                        }
                        return has
                    }).joined(separator: "\n")
                    DispatchQueue.main.async {
                        self._textView.text = content
                    }
                } else {
                    let content = lines.filter({ (line) -> Bool in
                        if let keyword = self._filterText?.lowercased() {
                            return line.lowercased().contains(keyword)
                        }
                        return true
                    }).joined(separator: "\n")
                    DispatchQueue.main.async {
                        self._textView.text = content
                    }
                }
            }
        }
        
        private func loopRead() {
            let timer = DispatchSource.makeTimerSource(flags: DispatchSource.TimerFlags(rawValue: 0), queue: _monitorQueue)
            let pageStepTime: DispatchTimeInterval = .seconds(1)
            timer.scheduleRepeating(deadline: .now() + pageStepTime, interval: pageStepTime)
            timer.setEventHandler(handler: {[weak self] in
                guard let sself = self, let file = sself._file else { return }
                if sself._lastReadPosition == FPLogger.shared.totalSize { return }
                var len = FPLogger.shared.totalSize - sself._lastReadPosition
                if len > 0 {
                    fseek(file, Int(sself._lastReadPosition), SEEK_SET)
                } else {
                    sself._total = ""
                    fseek(file, 0, SEEK_SET)
                    len = FPLogger.shared.totalSize
                }
                sself._lastReadPosition = FPLogger.shared.totalSize
                var bytes: [UInt8] = Array(repeating: 0, count: Int(len))
                fread(&bytes, 1, Int(len), file)
                let data = String(bytes: bytes, encoding: .utf8)?.replacingOccurrences(of: "\0", with: "")
                if let d = data {
                    DispatchQueue.main.async {
                        if sself._total.isEmpty {
                            sself._total = d
                        } else {
                            sself._total += d
                        }
                        sself.lines(filter: sself._filter)
                    }
                }
            })
            timer.resume()
            _timer = timer
        }
        
        // MARK:  UITextFieldDelegate
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            endEditing(true)
            if let t = textField.text, t.isEmpty == false {
                _filterText = textField.text
            } else {
                _filterText = nil
            }
            lines(filter: _filter)
            return true
        }
    }
    
#endif
