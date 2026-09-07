import AppKit
import Network
import Observation

/// A session shares one rendered document, never paths or the library filesystem.
@MainActor @Observable
final class LANReadingSync {
    var addresses: [String] = []
    var status = "尚未开启"
    var isRunning = false
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var token = ""
    private var session = UUID()
    private var snapshot: (() -> [String: Any]?)?
    private var receiveProgress: ((Int) -> Void)?

    func start(snapshot: @escaping () -> [String: Any]?, progress: @escaping (Int) -> Void) {
        stop()
        let hosts = Self.localAddresses()
        guard !hosts.isEmpty else { status = "未找到局域网 IPv4 地址，请先连接 Wi-Fi 或以太网。"; return }
        self.snapshot = snapshot
        receiveProgress = progress
        token = UUID().uuidString + UUID().uuidString
        let generation = session
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            isRunning = true
            status = "正在启动…"
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.session == generation else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else { return }
                        self.addresses = hosts.map { "http://\($0):\(port.rawValue)/#\(self.token)" }
                        self.status = "等待手机扫码"
                    case .failed(let error):
                        self.stop()
                        self.status = "启动失败：\(error.localizedDescription)"
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.session == generation, self.connections.count < 16 else { connection.cancel(); return }
                    let id = UUID()
                    self.connections[id] = connection
                    connection.start(queue: .main)
                    self.read(connection, id: id, buffer: Data())
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(10))
                        self?.connections.removeValue(forKey: id)?.cancel()
                    }
                }
            }
            listener.start(queue: .main)
        } catch { stop(); status = "启动失败：\(error.localizedDescription)" }
    }

    func stop() {
        session = UUID()
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        addresses = []; token = ""; snapshot = nil; receiveProgress = nil
        isRunning = false; status = "同步已关闭"
    }

    private func read(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var bytes = buffer
                if let data { bytes.append(data) }
                guard bytes.count <= 16384 else { self.reply(connection, id: id, code: 413); return }
                if let delimiter = bytes.range(of: Data("\r\n\r\n".utf8)) {
                    let header = String(decoding: bytes[..<delimiter.lowerBound], as: UTF8.self)
                    let lines = header.components(separatedBy: "\r\n")
                    let request = (lines.first ?? "").split(separator: " ").map(String.init)
                    var fields: [String: String] = [:]
                    for line in lines.dropFirst() {
                        guard let colon = line.firstIndex(of: ":") else { continue }
                        let key = line[..<colon].lowercased()
                        guard fields[key] == nil else { self.reply(connection, id: id, code: 400); return }
                        fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    }
                    guard request.count == 3, fields["transfer-encoding"] == nil,
                          let length = Int(fields["content-length"] ?? "0"), (0...4096).contains(length) else {
                        self.reply(connection, id: id, code: 400); return
                    }
                    let body = bytes[delimiter.upperBound...]
                    if body.count >= length {
                        self.handle(connection, id: id, method: request[0], path: request[1], fields: fields, body: Data(body.prefix(length)))
                        return
                    }
                }
                if done || error != nil { self.connections.removeValue(forKey: id)?.cancel() }
                else { self.read(connection, id: id, buffer: bytes) }
            }
        }
    }

    private func handle(_ connection: NWConnection, id: UUID, method: String, path: String, fields: [String: String], body: Data) {
        if method == "GET", path == "/" {
            reply(connection, id: id, type: "text/html; charset=utf-8", data: Data(Self.page.utf8)); return
        }
        guard fields["authorization"] == "Bearer \(token)", !token.isEmpty else { reply(connection, id: id, code: 403); return }
        guard let state = snapshot?() else { reply(connection, id: id, code: 410); return }
        if method == "GET", path == "/api/book" || path == "/api/progress" {
            var payload = state
            if path == "/api/progress" { payload.removeValue(forKey: "text"); payload.removeValue(forKey: "chapters") }
            status = "手机已连接 · 阅读位置同步中"
            reply(connection, id: id, data: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()); return
        }
        if method == "POST", path == "/api/progress" {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let version = object["version"] as? String, version == state["version"] as? String,
                  let offset = object["offset"] as? Int, let count = state["count"] as? Int,
                  (0...count).contains(offset) else { reply(connection, id: id, code: 409); return }
            receiveProgress?(offset)
            reply(connection, id: id, data: Data("{}".utf8)); return
        }
        reply(connection, id: id, code: 404)
    }

    private func reply(_ connection: NWConnection, id: UUID, code: Int = 200, type: String = "application/json", data: Data = Data()) {
        let header = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor in self?.connections.removeValue(forKey: id) }
        })
    }

    static func localAddresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return [] }
        defer { freeifaddrs(pointer) }
        var result: [String] = []
        var cursor = pointer
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let interface = item.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return Array(Set(result)).sorted()
    }

    static let page = #"""
<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>竹点阅读</title>
<style>
:root{color-scheme:light dark}*{box-sizing:border-box}body{margin:0;background:#f5f1e7;color:#302e29;font:19px/1.95 Georgia,'Songti SC',serif}header{position:sticky;top:0;background:#f5f1e7f5;padding:10px 18px;border-bottom:1px solid #dcd6c8;font:14px/1.5 system-ui;z-index:2}h1{font-size:16px;margin:0}#status{font-size:12px;color:#697766}nav{display:flex;gap:10px;margin-top:8px}button,select{font:14px system-ui;padding:7px;border:1px solid #ccc5b8;border-radius:6px;background:transparent;color:inherit}select{max-width:50%}main{max-width:760px;margin:auto;padding:24px 22px 85vh;overflow-wrap:anywhere}p{white-space:pre-wrap;margin:0 0 .6em;min-height:1em}body.night{background:#222521;color:#d7dccf}body.night header{background:#222521f5}
</style><header><h1 id="title">竹点阅读</h1><div id="status">正在连接电脑…</div><nav><select id="chapters" aria-label="章节"><option>章节目录</option></select><button id="smaller">A−</button><button id="larger">A＋</button><button id="theme">夜间</button></nav></header><main id="book"></main>
<script>
const token=location.hash.slice(1);history.replaceState(null,'',location.pathname);const status=document.querySelector('#status'), book=document.querySelector('#book');let revision=0;let version='',lastOffset=0,dirty=false,suppress=true,busy=false,ended=false,timer,paragraphs=[];
async function api(path,body){const r=await fetch('/api/'+path,{method:body?'POST':'GET',headers:{Authorization:'Bearer '+token,...(body?{'Content-Type':'application/json'}:{})},body:body?JSON.stringify(body):undefined,cache:'no-store'});if(!r.ok){if(r.status===410||r.status===403){ended=true;throw Error('同步已结束，请在电脑上重新开启并扫码')}if(r.status===409){const e=Error('正文已更新，正在重新载入');e.conflict=true;throw e}throw Error('同步暂不可用，请检查电脑和 Wi-Fi')}return r.json()}
function jump(offset){suppress=true;let p=paragraphs[0];for(const item of paragraphs){if(+item.dataset.offset>offset)break;p=item}if(p){const text=p.firstChild;if(text&&text.length){const range=document.createRange();const index=Math.min(Math.max(0,offset-(+p.dataset.offset)),text.length-1);range.setStart(text,index);range.setEnd(text,index+1);window.scrollTo(0,scrollY+range.getBoundingClientRect().top-document.querySelector('header').offsetHeight-12)}else p.scrollIntoView()}lastOffset=offset;setTimeout(()=>suppress=false,180)}
function position(){const y=document.querySelector('header').offsetHeight+14;let p=paragraphs.find(p=>p.getBoundingClientRect().bottom>y)||paragraphs.at(-1);if(!p)return 0;let offset=+p.dataset.offset;const caret=document.caretPositionFromPoint?.(p.getBoundingClientRect().left+2,y);const range=document.caretRangeFromPoint?.(p.getBoundingClientRect().left+2,y);if(caret&&caret.offsetNode===p.firstChild)offset+=caret.offset;else if(range&&range.startContainer===p.firstChild)offset+=range.startOffset;return offset}
async function load(){const data=await api('book');version=data.version;document.querySelector('#title').textContent=data.title;book.replaceChildren();let offset=0;const fragment=document.createDocumentFragment();for(const line of data.text.split('\n')){const p=document.createElement('p');p.dataset.offset=offset;p.textContent=line;fragment.append(p);offset+=line.length+1}book.append(fragment);paragraphs=[...book.children];const select=document.querySelector('#chapters');select.replaceChildren(new Option('章节目录',''));for(const c of data.chapters)select.add(new Option(c.title,c.offset));dirty=false;jump(data.offset);status.textContent='已连接 · 阅读位置自动同步'}
async function sync(){if(busy||ended)return;busy=true;try{if(dirty){const offset=position(),sentRevision=revision;await api('progress',{version,offset});lastOffset=offset;if(revision===sentRevision)dirty=false}const data=await api('progress');if(data.version!==version)await load();else if(!dirty&&data.offset!==lastOffset)jump(data.offset);status.textContent='已连接 · 阅读位置自动同步'}catch(e){status.textContent=e.message;if(e.conflict){try{await load()}catch(error){status.textContent=error.message}}}finally{busy=false}}
window.addEventListener('scroll',()=>{if(!suppress){revision++;dirty=true;clearTimeout(timer);timer=setTimeout(sync,500)}},{passive:true});document.querySelector('#chapters').onchange=e=>{if(e.target.value!==''){jump(+e.target.value);revision++;dirty=true;setTimeout(sync,200)}};let size=19;for(const [id,delta]of [['smaller',-1],['larger',1]])document.getElementById(id).onclick=()=>{const offset=position();size=Math.max(14,Math.min(32,size+delta));book.style.fontSize=size+'px';jump(offset)};document.querySelector('#theme').onclick=()=>document.body.classList.toggle('night');load().catch(e=>{status.textContent=e.message});setInterval(sync,2000);
</script></html>
"""#
}
