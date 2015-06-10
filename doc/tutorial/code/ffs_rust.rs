#[no_mangle]
pub extern fn ffs_ref(word: u32) -> u32 {
    if word == 0 {
        return 0;
    }
    for i in (0..32) {
        if ((1 << i) & word) != 0 {
            return i + 1;
        }
    }
    return 0;
}

#[no_mangle]
pub extern fn ffs_imp(mut i: u32) -> u32 {
    let mut n = 1;
    if (i & 0xffff) == 0 { n += 16; i >>= 16; }
    if (i & 0x00ff) == 0 { n += 8;  i >>= 8; }
    if (i & 0x000f) == 0 { n += 4;  i >>= 4; }
    if (i & 0x0003) == 0 { n += 2;  i >>= 2; }
    if i != 0 {
        n + ((i+1) & 0x01)
    } else {
        0
    }
}
