import 'dart:ffi';

typedef _InitNative =
    Int32 Function(Pointer<Void>, Pointer<Pointer<Char>>, Pointer<Void>);

@Native<_InitNative>(symbol: 'sqlite3_jieba_init')
external int _sqlite3JiebaInit(
  Pointer<Void> db,
  Pointer<Pointer<Char>> pzErrMsg,
  Pointer<Void> pApi,
);

/// Address of the extension entry point, as `sqlite3_auto_extension` wants it.
Pointer<Void> jiebaInitAddress() =>
    Native.addressOf<NativeFunction<_InitNative>>(_sqlite3JiebaInit).cast();
