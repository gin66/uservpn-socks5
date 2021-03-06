
use std::io;
use std::net::SocketAddr;
use tokio_core::net::UdpCodec;

// The message tail is watermarked with 3*64 bits.
// The three 64bit blocks are xored and give first half of 64bit word.
// Second half of 64bit word is a magic number.
// Both halfs are hashed to 128 bits.
// The hash first and second 64 bits are xored and yield the third 64 bits.
// This construction gives the watermark, which xored yields 0.
// 
#[allow(dead_code)]
pub struct MessageTail {   // Placed after payload
	// first 64 bit block
	pub magic: [u8; 4],
	pub time_s: u32,

	// second 64 bit block
	pub network_info: u32,
	pub origin_id: u8,
	pub origin_4ms: u8,
	pub crc_payload: u16,

	// third 64 bit block
	pub rand: u64,			// random part for generate random hash
}

// The message header is watermarked and as such should be of length n*128 bits aka 16 Bytes
// and n >= 3.
#[allow(dead_code)]
pub struct MessageInfo { // Can be placed after payload with few separating waste bytes
	// first 128 bit block
	pub magic: [u8; 8],
	pub index: u32,
	pub time_s: u32,

	// second 128 bit block
	pub key1: u64,			// key1/2 are used to crypt the payload with chacha20 and 128bit
	pub key2: u64,

	// third 128 bit block
	pub network_info: u32,
	pub payload_info: u8,  // 3 bits for number of waste bytes + 5 bits typ
	pub origin_4ms: u8,
	pub hop1_4ms: u8,
	pub hop2_4ms: u8,
	pub origin_id: u8,
	pub hop1_id: u8,
	pub hop2_id: u8,
	pub destination_id: u8,
	pub crc_payload: u16,
	pub pad1: u16,
}

pub struct MessageCodec {
    pub my_id:  u8, // This contains my own id. If UdpMessage matches, then payload will be decrypted.
    pub secret: u8  // Shared secret for encryption and decryption
}

// This should contain the encryption method for UdpMessages sent between peers and clients

impl UdpCodec for MessageCodec {
	type In = (SocketAddr, Vec<u8>);
	type Out = (SocketAddr, Vec<u8>);

	fn decode(&mut self, addr: &SocketAddr, buf: &[u8]) -> Result<Self::In, io::Error> {
		Ok((*addr, buf.to_vec()))
	}

	fn encode(&mut self, (addr, buf): Self::Out, into: &mut Vec<u8>) -> SocketAddr {
		into.extend(buf);
		addr
	}
}

