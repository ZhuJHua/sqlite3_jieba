fn main() {
    println!("cargo:rerun-if-changed=c/shim.c");
    println!("cargo:rerun-if-changed=c/fts5.h");
    println!("cargo:rerun-if-changed=c/sqlite3.h");
    println!("cargo:rerun-if-changed=c/sqlite3ext.h");
    cc::Build::new()
        .file("c/shim.c")
        .include("c")
        .warnings(true)
        .compile("sqlite3_jieba_shim");
}
