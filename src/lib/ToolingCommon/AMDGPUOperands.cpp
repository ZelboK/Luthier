//===-- AMDGPUOperands.cpp - Luthier AMDGPU operand helpers ---------------===//
//
// See \c include/luthier/Tooling/AMDGPUOperands.h for the rationale.
// These wrappers exist purely to give downstream Luthier tool `.so`s a
// stable, Luthier-exported entry point into a few AMDGPU codegen helpers
// that LLVM 23 keeps internal to the AMDGPU target archives.
//===----------------------------------------------------------------------===//
#include "luthier/Tooling/AMDGPUOperands.h"

#include "GCNSubtarget.h"
#include "SIInstrInfo.h"
#include "Utils/AMDGPUBaseInfo.h"
#include <llvm/CodeGen/MachineInstr.h>

namespace luthier::amdgpu {

int getNamedOperandIdx(uint32_t Opcode, llvm::AMDGPU::OpName Name) {
  return llvm::AMDGPU::getNamedOperandIdx(Opcode, Name);
}

bool hasNamedOperand(uint32_t Opcode, llvm::AMDGPU::OpName Name) {
  return llvm::AMDGPU::hasNamedOperand(Opcode, Name);
}

bool isAlwaysGDS(const llvm::SIInstrInfo &TII, uint32_t Opcode) {
  return TII.isAlwaysGDS(Opcode);
}

bool hasModifiersSet(const llvm::SIInstrInfo &TII,
                     const llvm::MachineInstr &MI,
                     llvm::AMDGPU::OpName Name) {
  return TII.hasModifiersSet(MI, Name);
}

bool isDS(const llvm::MachineInstr &MI) { return llvm::SIInstrInfo::isDS(MI); }

} // namespace luthier::amdgpu
