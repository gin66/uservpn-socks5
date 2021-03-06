use "net"
use "time"
use "logger"
use "collections"

primitive Socks5WaitInit
primitive Socks5WaitRequest
primitive Socks5WaitConnect
primitive Socks5WaitMethodSelection
primitive Socks5WaitReply
primitive Socks5PassThrough

type Socks5ServerState is (Socks5WaitInit | Socks5WaitRequest | Socks5WaitConnect)
type Socks5ClientState is (Socks5WaitConnect | Socks5WaitMethodSelection | Socks5WaitReply | Socks5PassThrough)

primitive Socks5
    fun version():U8 => 5
    fun meth_no_auth():U8 => 0
    fun meth_gssapi():U8 => 1
    fun meth_user_pass():U8 => 2
    fun cmd_connect():U8 => 1
    fun cmd_bind():U8 => 2
    fun cmd_udp_associate():U8 => 3
    fun atyp_ipv4():U8 => 1
    fun atyp_ipv6():U8 => 4
    fun atyp_domain():U8 => 3
    fun reply_ok():U8 => 0
    fun reply_general_error():U8 => 1
    fun reply_not_allowed():U8 => 2
    fun reply_net_unreachable():U8 => 3
    fun reply_host_unreachable():U8 => 4
    fun reply_conn_refused():U8 => 5
    fun reply_ttl_expired():U8 => 6
    fun reply_cmd_not_supported():U8 => 7
    fun reply_atyp_not_supported():U8 => 8

    fun make_request_ipv4(ip: (U8,U8,U8,U8)): Array[U8] iso^ =>
        let req: Array[U8] iso = recover Array[U8](10) end
        (let ip1,let ip2,let ip3,let ip4) = ip
        req.push(Socks5.version())
        req.push(Socks5.cmd_connect())
        req.push(0)
        req.push(Socks5.atyp_ipv4())
        req.push(ip1)
        req.push(ip2)
        req.push(ip3)
        req.push(ip4)
        req.push(0)
        req.push(80)
        consume req

    fun make_request(host: String): Array[U8] iso^ =>
        let req: Array[U8] iso = recover Array[U8](host.size()+7) end
        req.push(Socks5.version())
        req.push(Socks5.cmd_connect())
        req.push(0)
        req.push(Socks5.atyp_domain())
        req.push(U8.from[USize](host.size()))
        for ch in host.values() do
            req.push(ch)
        end
        req.push(0)
        req.push(80)
        consume req

class SocksTCPConnectionNotify is TCPConnectionNotify
    let _auth:     AmbientAuth val
    let _chooser:  Chooser
    let _logger:   Logger[String]
    var _state:    Socks5ServerState
    var _tx_bytes: USize = 0
    var _rx_bytes: USize = 0

    new iso create(auth: AmbientAuth val, chooser: Chooser, logger: Logger[String]) =>
        _auth     = auth
        _chooser  = chooser
        _logger   = logger
        _state    = Socks5WaitInit

    fun ref received(
            conn: TCPConnection ref,
            data: Array[U8] iso,
            times: USize)
            : Bool =>
        try 
            _rx_bytes = _rx_bytes + data.size()
            for i in Range(0,data.size()) do
                _logger(Fine) and _logger.log(i.string()+":"+data(i)?.string())
            end
            match _state
            | Socks5WaitInit =>
                _logger(Fine) and _logger.log("Received handshake")
                if data(0)? != Socks5.version() then error end
                if data.size() != (USize.from[U8](data(1)?) + 2) then error end
                data.find(Socks5.meth_no_auth(), 2)?
                _logger(Fine) and _logger.log("Send initial response")
                conn.write([Socks5.version();Socks5.meth_no_auth()])
                _state = Socks5WaitRequest
            | Socks5WaitRequest =>
                _logger(Fine) and _logger.log("Received address")
                if data(0)? != Socks5.version() then error end
                if data(1)? != Socks5.cmd_connect() then
                    data(1)? = Socks5.reply_cmd_not_supported()
                    conn.write(consume data)
                    error
                end
                var atyp_len: USize = 0
                var port: U16 = U16.from[U8](data(data.size()-2)?)
                port = (port * 256) + U16.from[U8](data(data.size()-1)?)
                var addr: InetAddrPort iso
                match data(3)?
                | Socks5.atyp_ipv4()   => 
                    atyp_len = 4
                    let ip  = (data(4)?,data(5)?,data(6)?,data(7)?)
                    addr = InetAddrPort(ip,port)
                | Socks5.atyp_domain() => 
                    atyp_len = USize.from[U8](data(4)?)+1
                    var dest : String iso = recover iso String(atyp_len) end
                    for i in Range(0,atyp_len-1) do
                        dest.push(data(5+i)?)
                    end
                    addr  = InetAddrPort.create_from_string(consume dest,port)
                else
                    data(1)? = Socks5.reply_atyp_not_supported()
                    conn.write(consume data)
                    error
                end
                if data.size() != (atyp_len + 6) then
                    error
                end
                // The dialer should call set_notify on actor conn.
                // This means, no more communication should happen with this notifier
                Dialer(_auth,_chooser,conn,consume addr,consume data,_logger)
                _state = Socks5WaitConnect
            | Socks5WaitConnect=>
                _logger(Fine) and _logger.log("Received data, while waiting for connection")
                error
                //conn.write(String.from_array(consume data))
            end
        else
            conn.dispose()
        end
        false

    fun ref sent(
            conn: TCPConnection ref,
            data: (String val | Array[U8] val))
            : (String val | Array[U8 val] val) =>
        _tx_bytes = _tx_bytes + data.size()
        data

    fun ref throttled(conn: TCPConnection ref) =>
        None

    fun ref unthrottled(conn: TCPConnection ref) =>
        None

    fun ref accepted(conn: TCPConnection ref) =>
        None

    fun ref connect_failed(conn: TCPConnection ref) =>
        None

    fun ref closed(conn: TCPConnection ref) =>
        _logger(Fine) and _logger.log("Connection closed tx/rx=" + _tx_bytes.string() + "/" + _rx_bytes.string())

class SocksTCPListenNotify is TCPListenNotify
    let _auth: AmbientAuth val
    let _chooser: Chooser
    let _logger: Logger[String]

    new iso create(auth: AmbientAuth val, chooser: Chooser, logger: Logger[String]) =>
        _auth     = auth
        _chooser  = chooser
        _logger   = logger

    fun ref connected(listen: TCPListener ref): TCPConnectionNotify iso^ =>
        SocksTCPConnectionNotify(_auth, _chooser, _logger)

    fun ref listening(listen: TCPListener ref) =>
        _logger(Fine) and _logger.log("Successfully bound to address")

    fun ref not_listening(listen: TCPListener ref) =>
        _logger(Fine) and _logger.log("Cannot bind to listen address")

    fun ref closed(listen: TCPListener ref) =>
        _logger(Fine) and _logger.log("Successfully closed TCP listeners")


class Socks5OutgoingTCPConnectionNotify is TCPConnectionNotify
    var _dialer:   Dialer tag
    let _peer:     PeerConnection
    var _tx_bytes: USize = 0
    var _rx_bytes: USize = 0
    var _state:    Socks5ClientState
    var _route_id: USize
    let _start_ms: U64
    var _conn_ms:  U64
    var _auth_ms:  U64
    let _logger:   Logger[String]

    new iso create(dialer: Dialer,
                   route_id: USize,
                   peer: PeerConnection, 
                   logger: Logger[String]) =>
        _dialer   = dialer
        _route_id = route_id
        _peer     = peer
        _state    = Socks5WaitConnect
        _start_ms = Time.millis()
        _conn_ms  = 0
        _auth_ms  = 0
        _logger   = logger

    fun ref connect_failed(conn: TCPConnection ref) =>
        _logger(Fine) and _logger.log("Connection to socks proxy failed")
        _dialer.outgoing_socks_connection_failed(_route_id,conn)

    fun ref connected(conn: TCPConnection ref) =>
        _logger(Fine) and _logger.log("Connection to socks proxy succeeded")
        _state  = Socks5WaitMethodSelection
        _conn_ms = Time.millis() - _start_ms
        conn.write([Socks5.version();1;Socks5.meth_no_auth()])

    fun ref received(
            conn: TCPConnection ref,
            data: Array[U8] iso,
            times: USize)
            : Bool =>
        _logger(Fine) and _logger.log("Received " + data.size().string() + " Bytes")
        _rx_bytes = _rx_bytes + data.size()
        match _state
        | Socks5WaitMethodSelection =>
            try
                if data.size() != 2 then error end
                if data(0)? != Socks5.version() then error end
                if data(1)? != Socks5.meth_no_auth() then error end
                _logger(Fine) and _logger.log("Reply from socks proxy OK")
                _auth_ms = Time.millis() - _start_ms
                _state = Socks5WaitReply
                _dialer.outgoing_socks_connection_succeeded(conn)
                return false
            end
        | Socks5WaitReply =>
            try
                _logger(Fine) and _logger.log("Reply from socks proxy received")
                if (data(0)? == Socks5.version()) and (data(1)? == Socks5.reply_ok()) then
                    let delta_ms = Time.millis() - _start_ms
                    _dialer.outgoing_socks_connection_established(_route_id,_conn_ms,
                                                                            _auth_ms,delta_ms)
                end
                _state = Socks5PassThrough
                _peer.write(consume data)
                return false
            end
        | Socks5PassThrough =>
            _peer.write(consume data)
            return false
        end
        _dialer.outgoing_socks_connection_failed(_route_id,conn)
        conn.dispose()
        false

    fun ref sent(
            conn: TCPConnection ref,
            data: (String val | Array[U8] val))
            : (String val | Array[U8 val] val) =>
        _tx_bytes = _tx_bytes + data.size()
        data

    fun ref throttled(conn: TCPConnection ref) =>
        _peer.mute()

    fun ref unthrottled(conn: TCPConnection ref) =>
        _peer.unmute()

    fun ref closed(conn: TCPConnection ref) =>
        _logger(Fine) and _logger.log("Connection closed tx/rx=" + _tx_bytes.string() + "/" + _rx_bytes.string())
        _peer.dispose()
        if not(_state is Socks5PassThrough) then
            _dialer.outgoing_socks_connection_failed(_route_id,conn)
        end

    
class Socks5ProbeTCPConnectionNotify is TCPConnectionNotify
    var _state:    Socks5ClientState
    let _host:     String
    let _host_id:  U8
    let _route_id: U8
    let _logger:   Logger[String]

    new iso create(probe_host:String,host_id:U8,route_id:USize,
                        logger: Logger[String]) =>
        _state    = Socks5WaitConnect
        _host     = probe_host
        _host_id  = host_id
        _route_id = U8.from[USize](route_id)
        _logger   = logger

    fun ref connect_failed(conn: TCPConnection ref) =>
        _logger(Fine) and _logger.log("Probe connection to socks proxy failed")

    fun ref connected(conn: TCPConnection ref) =>
        _logger(Fine) and _logger.log("Probe connection to socks proxy succeeded")
        _state  = Socks5WaitMethodSelection
        conn.write([Socks5.version();1;Socks5.meth_no_auth()])

    fun ref received(
            conn: TCPConnection ref,
            data: Array[U8] iso,
            times: USize)
            : Bool =>
        _logger(Fine) and _logger.log("Received " + data.size().string() + " Bytes")
        match _state
        | Socks5WaitMethodSelection =>
            try
                if data.size() != 2 then error end
                if data(0)? != Socks5.version() then error end
                if data(1)? != Socks5.meth_no_auth() then error end
                _logger(Fine) and _logger.log("Reply from socks proxy OK")
                _state = Socks5WaitReply
                let ip: (U8,U8,U8,U8) = (0,0,_host_id,_route_id)
                let msg = recover Socks5.make_request_ipv4(ip) end
                conn.write(consume msg)
                return false
            end
        | Socks5WaitReply =>
            try
                _logger(Fine) and _logger.log("Reply from socks proxy received")
                if data(0)? != Socks5.version() then error end
                if data(1)? != Socks5.reply_ok() then error end
                _state = Socks5PassThrough
                _logger(Fine) and _logger.log("Send http GET request")
                let msg = recover 
                        "GET /robots.txt HTTP/1.1\r\nHost: " 
                          + _host 
                          + "\r\nUser-Agent: none\r\nAccept: */*\r\n\r\n"
                    end
                conn.write(consume msg)
                return false
            end
        | Socks5PassThrough =>
            _logger(Fine) and _logger.log("Received reply:" + data.size().string())
            //_logger.log(String.from_array(consume data))
            //return false .... fall through and close connection
        end
        conn.dispose()
        false

    fun ref closed(conn: TCPConnection ref) =>
        _logger(Fine) and _logger.log("Proxy connection closed")
