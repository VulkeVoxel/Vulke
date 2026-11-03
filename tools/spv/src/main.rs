use naga::valid::{Capabilities, ValidationFlags, Validator};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let src = std::fs::read_to_string(&args[1]).expect("read shader");
    let module = match naga::front::wgsl::parse_str(&src) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("{}", e.emit_to_string(&src));
            std::process::exit(1);
        }
    };
    let mut validator = Validator::new(ValidationFlags::all(), Capabilities::all());
    let info = match validator.validate(&module) {
        Ok(i) => i,
        Err(e) => {
            eprintln!("{}", e.emit_to_string(&src));
            std::process::exit(1);
        }
    };
    let mut opts = naga::back::spv::Options::default();
    opts.flags &= !naga::back::spv::WriterFlags::ADJUST_COORDINATE_SPACE;
    let words = naga::back::spv::write_vec(&module, &info, &opts, None).expect("spirv");
    let mut bytes = Vec::with_capacity(words.len() * 4);
    for w in words {
        bytes.extend_from_slice(&w.to_le_bytes());
    }
    std::fs::write(&args[2], &bytes).expect("write output");
    println!("wrote {} ({} bytes)", args[2], bytes.len());
}
