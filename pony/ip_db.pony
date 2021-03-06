use "files"
use "logger"
use "regex"
use "promises"
use "collections"

actor IpDB
    """
    the private IP addresses resolve to ZZ
    """

    var db_from : Array[U32] = Array[U32](460589)
    var db_to   : Array[U32] = Array[U32](460589)
    var cn      : Array[U16] = Array[U16](460589)
    let _pending: Array[(Array[U32] val,Promise[String])] = Array[(Array[U32] val,Promise[String])]
    let _logger : Logger[String]
    var _is_loaded : Bool = false

    new create(logger: Logger[String]) =>
        _logger = logger

    be start_load(filename: FilePath) =>
        try
            let ip  = "\"(\\d+)\\.(\\d+)\\.(\\d+)\\.(\\d+)\""
            let rex = recover Regex(ip + "," + ip + ",\"([A-Z][A-Z])\"")? end
            match recover OpenFile(filename) end
            | let file: File iso =>
                _logger(Fine) and _logger.log("Start load of Geo IP database")
                process_chunk(consume file,consume rex)
            else
                _logger(Fine) and _logger.log("Error opening file '" + filename.path + "'")
            end
        end

    be process_chunk(file: File iso, rex: Regex val) =>
        try
            // Process file in chunks of approx. <chunk> Bytes
            let chunk: USize = 10000
            let up_to = file.position() + chunk
            while file.position() < up_to do
                let line: String val = file.line()?
                _logger(Fine) and _logger.log(line)
                try
                    let matched = rex(line)?
                    var from_ip: U32 = 0
                    var to_ip:   U32 = 0
                    var country: U16 = 0

                    from_ip = matched(1)?.u32()?
                    from_ip = (from_ip << 8) + matched(2)?.u32()?
                    from_ip = (from_ip << 8) + matched(3)?.u32()?
                    from_ip = (from_ip << 8) + matched(4)?.u32()?
                    to_ip = matched(5)?.u32()?
                    to_ip = (to_ip << 8) + matched(6)?.u32()?
                    to_ip = (to_ip << 8) + matched(7)?.u32()?
                    to_ip = (to_ip << 8) + matched(8)?.u32()?
                    country = U16.from[U8](matched(9)?(0)?)
                    country = U16.from[U8](matched(9)?(1)?) + (country<<8)
                    db_from.push(from_ip)
                    db_to.push(to_ip)
                    cn.push(country)
                    _logger(Fine) and _logger.log(from_ip.string()+" "+to_ip.string()+" "+country.string())
                end
            end
            process_chunk(consume file,consume rex)
        else
            _logger(Info) and _logger.log("Geo IP database load completed")
            _is_loaded = true
            try 
                while true do
                    (let addr,let promise) = _pending.pop()?
                    _do_locate(addr,promise)                    
                end
            end
        end

    fun tag locate(ips: Array[U32] val): Promise[String] =>
        let promise = Promise[String]
        _do_locate(ips,promise)
        promise

    be _do_locate(ips: Array[U32] val, promise: Promise[String]) =>
        if _is_loaded then
            let countries = recover iso String(3*ips.size()) end
            for ip in ips.values() do
               let country = _u16_to_country(_locate(ip))
                _logger(Fine) and _logger.log("Country for " + ip.string() + " is " + country)
                if not countries.contains(country) then
                    if countries.size() > 0 then
                        countries.append(",")
                    end
                    countries.append(country)
                end
            end
            promise(consume countries)
        else
            _pending.push( (ips,promise) )
        end

    fun tag _u16_to_country(code: U16): String val =>
        var ans = recover String(2) end
        ans.push(U8.from[U16](code >> 8))
        ans.push(U8.from[U16](code % 256))
        ans

    fun ref _locate(addr: U32): U16 =>
        // Offset 1, because j could be -1 otherwise
        var i: USize = 1
        var j: USize = db_from.size()
        var k: USize = 1
        while i <= j do
            k = (i+j)>>1
            try
                if addr < db_from(k-1)? then
                    j = k-1
                elseif addr > db_from(k-1)? then
                    i = k+1
                else
                    return cn(k-1)?
                end
            else
               _logger(Error) and _logger.log("Error"+k.string()+""+i.string()
                        +"/"+j.string()) 
                return 0
            end
        end
        try
            _logger(Fine) and _logger.log(i.string()+"/"+j.string()+"/"+k.string())
            if (j > 1) and (db_from(j-1)? <= addr) and (addr <= db_to(j-1)?) then
                cn(j-1)?
            else
                0
            end
        else
            0 
        end
