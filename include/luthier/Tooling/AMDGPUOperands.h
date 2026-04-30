//===-- AMDGPUOperands.h - Luthier AMDGPU operand helpers ------*- C++ -*-===//
//
// Tiny re-exports of a few llvm::AMDGPU helpers that are needed by Luthier
// tool consumers (e.g. examples/LDSBankConflict) but are not part of LLVM's
// public ABI surface.
//
// LLVM 23 builds its target backends with `-fvisibility=hidden` and exposes
// only symbols annotated with `LLVM_ABI` (or its dylib equivalent). Several
// AMDGPU helpers that Luthier's example tools rely on
// (e.g. `llvm::AMDGPU::getNamedOperandIdx`, `llvm::SIInstrInfo::isAlwaysGDS`)
// are intentionally *not* annotated for export, since they were historically
// static-linked into target backends. When `libLuthierTooling.so` statically
// links those archives, the symbols end up with `LOCAL` binding inside the
// `.so` and are unreachable from downstream tool `.so`s.
//
// We can't add a separate static link of `LLVMAMDGPU*.a` to the consuming
// tool either: each AMDGPU codegen TU registers process-global `cl::opt`
// instances at static-init time, so loading two `.so`s that each include
// those archives causes a duplicate-option crash.
//
// The minimum-disruption fix is to expose the exact small subset of
// AMDGPU helpers that Luthier examples actually call as Luthier-owned
// wrappers. Luthier compiles its own sources with default visibility, so
// these wrappers are exported from `libLuthierTooling.so` and resolve
// cleanly from any consuming `.so`.
//===----------------------------------------------------------------------===//
#ifndef LUTHIER_TOOLING_AMDGPU_OPERANDS_H
#define LUTHIER_TOOLING_AMDGPU_OPERANDS_H

#include <cstdint>

namespace llvm {
class MachineInstr;
class SIInstrInfo;
namespace AMDGPU {
// LLVM 23's TableGen-generated AMDGPU OpName uses uint8_t as its underlying
// type. Match it here so the forward declaration is ABI-compatible.
enum class OpName : uint8_t;
} // namespace AMDGPU
} // namespace llvm

namespace luthier::amdgpu {

/// Wrapper around \c llvm::AMDGPU::getNamedOperandIdx exported with default
/// visibility for downstream tool consumers.
int getNamedOperandIdx(uint32_t Opcode, llvm::AMDGPU::OpName Name);

/// Wrapper around \c llvm::AMDGPU::hasNamedOperand. Inline in LLVM but worth
/// re-wrapping here to keep the example's call sites uniform.
bool hasNamedOperand(uint32_t Opcode, llvm::AMDGPU::OpName Name);

/// Wrapper around \c llvm::SIInstrInfo::isAlwaysGDS.
bool isAlwaysGDS(const llvm::SIInstrInfo &TII, uint32_t Opcode);

/// Wrapper around \c llvm::SIInstrInfo::hasModifiersSet for the gds-style
/// flag the LDS bank conflict example reads.
bool hasModifiersSet(const llvm::SIInstrInfo &TII,
                     const llvm::MachineInstr &MI, llvm::AMDGPU::OpName Name);

/// Wrapper around \c llvm::SIInstrInfo::isDS (free function form, since the
/// underlying LLVM API is a static method on SIInstrInfo).
bool isDS(const llvm::MachineInstr &MI);

} // namespace luthier::amdgpu

#endif // LUTHIER_TOOLING_AMDGPU_OPERANDS_H
