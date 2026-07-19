/* shim.c — the entire C footprint of the Sol JIT.
 *
 * LLVMInitializeNativeTarget & friends are static inline functions in
 * llvm-c/Target.h, so Haskell FFI cannot bind them directly; everything
 * else in the JIT talks straight to libLLVM through plain FFI imports.
 */
#include <llvm-c/Target.h>

int sol_llvm_init(void) {
  if (LLVMInitializeNativeTarget()) return 1;
  if (LLVMInitializeNativeAsmPrinter()) return 2;
  return 0;
}
