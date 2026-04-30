//===-- LDSBankConflict.hip -------------------------------------*- C++ -*-===//
// Copyright 2022-2025 @ Northeastern University Computer Architecture Lab
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//
///
/// \file
/// This file implements a sample LDS Bank Conflict detector in wave-fronts
/// using Luthier.
/// The tool was inspired by NVBit paper's cache simulator example.
//===----------------------------------------------------------------------===//
#define HIP_ENABLE_WARP_SYNC_BUILTINS
#include <GCNSubtarget.h>
#include <SIInstrInfo.h>
#include <llvm/ADT/APFloat.h>
#include <llvm/ADT/StringMap.h>
#include <llvm/CodeGen/TargetInstrInfo.h>
#include <llvm/Demangle/Demangle.h>
#include <llvm/IR/Constants.h>
#include <llvm/Support/CommandLine.h>
#include <llvm/Support/FormatVariadic.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/PrettyStackTrace.h>
#include <llvm/Support/raw_ostream.h>
#include <luthier/HIP/HipError.h>
#include <luthier/HSA/HsaError.h>
#include <luthier/LLVM/streams.h>
#include <luthier/luthier.h>
#include <luthier/Rocprofiler/ApiTableSnapshot.h>
#include <luthier/Tooling/AMDGPUOperands.h>
#include <luthier/Tooling/Context.h>
#include <luthier/Tooling/ToolExecutableLoader.h>
#include <dlfcn.h>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <mutex>
#include <thread>
#include <vector>

#undef DEBUG_TYPE
#define DEBUG_TYPE "luthier-example-lds-bank-conflict"

using namespace luthier;

//===----------------------------------------------------------------------===//
// Commandline arguments for the tool
//===----------------------------------------------------------------------===//
static llvm::cl::OptionCategory *LDSBankConflictToolOptionCategory;

static llvm::cl::opt<unsigned int> *InstrBeginInterval;

static llvm::cl::opt<unsigned int> *InstrEndInterval;

static llvm::cl::opt<unsigned int> *KernelBeginInterval;

static llvm::cl::opt<unsigned int> *KernelEndInterval;

static llvm::cl::opt<bool> *DemangleKernelNames;

static llvm::cl::opt<unsigned> *Log2BankSize;

static llvm::cl::opt<std::string> *KernelNameFilter;

//===----------------------------------------------------------------------===//
// Global variables of the tool
//===----------------------------------------------------------------------===//
/// Where the controller singleton is stored
static Context *C{nullptr};

/// Where the HIP runtime table is stored
static rocprofiler::HipApiTableSnapshot<ROCPROFILER_HIP_RUNTIME_TABLE>
    *HipRuntimeTableSnapshot{nullptr};

static bool DynamicModuleBitcodeLoaded{false};
static constexpr unsigned MaxTrackedLDSInstructions = 65536;

#ifndef LUTHIER_LDS_HOST_ONLY
__attribute__((device)) float
    InstructionBankConflicts[MaxTrackedLDSInstructions];

__attribute__((device)) uint64_t
    InstructionExecutionCounts[MaxTrackedLDSInstructions];
#endif

/// Number of kernels launched so far
static uint32_t NumKernelLaunched = 0;

std::recursive_mutex Mutex;

#ifndef LUTHIER_LDS_HOST_ONLY
__device__ static float getExtraBankConflictCount(float WorkItemsWithSameBank) {
  return (WorkItemsWithSameBank - 1.f) / WorkItemsWithSameBank;
}

__device__ static unsigned getLDSBankIndex(unsigned Address,
                                           unsigned CacheSizeLog2) {
  return (Address >> CacheSizeLog2) & 31u;
}
#endif

struct InstrumentedLDSInstruction {
  unsigned Id;
  unsigned GlobalInstructionIndex;
  std::string FunctionName;
  std::string OpcodeName;
  std::string MachineInstr;
};

static llvm::StringMap<std::vector<InstrumentedLDSInstruction>>
    KernelInstructionMetadata;

#ifdef LUTHIER_LDS_HOST_ONLY
static llvm::Error ensureDynamicModuleReady(hsa_agent_t Agent) {
  auto &TEM = luthier::ToolExecutableLoader::instance();
  auto &DIM = TEM.getDynamicInstrumentationModule();
  TEM.useDynamicInstrumentationModule();

  if (!DynamicModuleBitcodeLoaded) {
    Dl_info Info{};
    if (dladdr(reinterpret_cast<void *>(&ensureDynamicModuleReady), &Info) ==
            0 ||
        Info.dli_fname == nullptr) {
      return llvm::createStringError(
          std::errc::invalid_argument,
          "Failed to locate the LDSBankConflict host library path.");
    }

    auto BitcodePath = std::filesystem::path(Info.dli_fname).parent_path() /
                       "LuthierLDSBankConflictDevice.bc";
    auto Buffer = llvm::MemoryBuffer::getFile(BitcodePath.string());
    if (!Buffer) {
      return llvm::createStringError(
          std::errc::invalid_argument,
          "Failed to load %s: %s", BitcodePath.c_str(),
          Buffer.getError().message().c_str());
    }
    DIM.setBitcode((*Buffer)->getBuffer());
    DynamicModuleBitcodeLoaded = true;
  }

  auto ExistingBankConflicts =
      DIM.getGlobalVariablesLoadedOnAgent("InstructionBankConflicts", Agent);
  LUTHIER_RETURN_ON_ERROR(ExistingBankConflicts.takeError());
  if (ExistingBankConflicts->has_value())
    return llvm::Error::success();

  void *BankConflicts = nullptr;
  void *ExecutionCounts = nullptr;
  LUTHIER_RETURN_ON_ERROR(LUTHIER_HIP_CALL_ERROR_CHECK(
      HipRuntimeTableSnapshot->getTable()
          .callFunction<&::HipDispatchTable::hipMalloc_fn>(
              &BankConflicts, sizeof(float) * MaxTrackedLDSInstructions),
      "Failed to allocate LDS bank-conflict device counter buffer"));
  LUTHIER_RETURN_ON_ERROR(LUTHIER_HIP_CALL_ERROR_CHECK(
      HipRuntimeTableSnapshot->getTable()
          .callFunction<&::HipDispatchTable::hipMalloc_fn>(
              &ExecutionCounts, sizeof(uint64_t) * MaxTrackedLDSInstructions),
      "Failed to allocate LDS instruction execution-count device buffer"));

  LUTHIER_RETURN_ON_ERROR(DIM.registerGlobalVariableAddress(
      "InstructionBankConflicts", Agent,
      reinterpret_cast<luthier::address_t>(BankConflicts)));
  LUTHIER_RETURN_ON_ERROR(DIM.registerGlobalVariableAddress(
      "InstructionExecutionCounts", Agent,
      reinterpret_cast<luthier::address_t>(ExecutionCounts)));
  return llvm::Error::success();
}
#endif

#ifndef LUTHIER_LDS_HOST_ONLY
MARK_LUTHIER_DEVICE_MODULE

///
/// \param M0
/// \param VAddr
/// \param Offset
/// \param CacheSizeLog2
LUTHIER_HOOK_ANNOTATE
countUniqueBanksPerWarpSingleAddress(uint32_t InstructionId, unsigned int M0,
                                     unsigned int VAddr,
                                     short Offset, short CacheSizeLog2) {
  // Get the exec mask of the wavefront
  unsigned long long int ExecMask = __builtin_amdgcn_read_exec();
  // Get the position of the thread in the current wavefront (1-index)
  const uint32_t LaneId = __lane_id() + 1;
  // Get the first active thread id inside this wavefront
  unsigned int FirstActiveThreadId = __ffsll(ExecMask);
  // Have only the first active thread perform the atomic add
  if (FirstActiveThreadId == LaneId) {
    atomicAdd(&InstructionExecutionCounts[InstructionId], 1);
  }

  // Calculate the LDS address accessed by this instruction
  unsigned int Address = M0 + VAddr + Offset;
  // Calculate this work-item's bank ID
  unsigned int BankIdx = getLDSBankIndex(Address, CacheSizeLog2);
  // Count how many other work-items in the warp have the same bank ID
  auto NumWorkItemsWithSameBankID =
      static_cast<float>(__popcll(__match_any(BankIdx)));
  atomicAdd(&InstructionBankConflicts[InstructionId],
            getExtraBankConflictCount(NumWorkItemsWithSameBankID));
}

LUTHIER_EXPORT_HOOK_HANDLE(countUniqueBanksPerWarpSingleAddress);

///
/// \param M0
/// \param VAddr
/// \param Offset0
/// \param Offset1
/// \param CacheSizeLog2
LUTHIER_HOOK_ANNOTATE
countUniqueBanksPerWarpDoubleAddress(uint32_t InstructionId, unsigned int M0,
                                     unsigned int VAddr,
                                     uint8_t Offset0, uint8_t Offset1,
                                     short CacheSizeLog2) {
  // Get the exec mask of the wavefront
  unsigned long long int ExecMask = __builtin_amdgcn_read_exec();
  // Get the position of the thread in the current wavefront (1-index)
  const uint32_t LaneId = __lane_id() + 1;
  // Get the first active thread id inside this wavefront
  unsigned int FirstActiveThreadId = __ffsll(ExecMask);
  // Have only the first active thread perform the atomic add
  if (FirstActiveThreadId == LaneId) {
    atomicAdd(&InstructionExecutionCounts[InstructionId], 1);
  }

  // Calculate the LDS addresses accessed by this instruction
  unsigned int Address0 = M0 + VAddr + (Offset0 << 2);

  unsigned int Address1 = M0 + VAddr + (Offset1 << 2);
  // Calculate this work-item's bank IDs
  unsigned int BankIdx0 = getLDSBankIndex(Address0, CacheSizeLog2);
  unsigned int BankIdx1 = getLDSBankIndex(Address1, CacheSizeLog2);
  // Count how many other work-items in the warp have the same bank ID
  auto NumWorkItemsWithSameBankID0 =
      static_cast<float>(__popcll(__match_any(BankIdx0)));
  auto NumWorkItemsWithSameBankID1 =
      static_cast<float>(__popcll(__match_any(BankIdx1)));
  // We also have to count the conflict between BankIdx0 of
  // this thread and BankIdx1 of other threads
  for (uint32_t I = 0; I < 64; I++) {
    if (LaneId != I) {
      unsigned int BankIdx0IthThread = __shfl_sync(ExecMask, BankIdx0, I);
      if (BankIdx0IthThread == BankIdx1)
        NumWorkItemsWithSameBankID1++;
      unsigned int BankIdx1IthThread = __shfl_sync(ExecMask, BankIdx1, I);
      if (BankIdx1IthThread == BankIdx0)
        NumWorkItemsWithSameBankID0++;
    }
  }

  atomicAdd(&InstructionBankConflicts[InstructionId],
            getExtraBankConflictCount(NumWorkItemsWithSameBankID0));
  atomicAdd(&InstructionBankConflicts[InstructionId],
            getExtraBankConflictCount(NumWorkItemsWithSameBankID1));
}
LUTHIER_EXPORT_HOOK_HANDLE(countUniqueBanksPerWarpDoubleAddress);

LUTHIER_HOOK_ANNOTATE countUniqueBanksPerWarpDoubleAddressTwoSource32(
    uint32_t InstructionId, unsigned int M0, unsigned int VAddr,
    uint16_t Offset0, uint16_t Offset1, uint8_t CacheSizeLog2) {
  // Get the exec mask of the wavefront
  unsigned long long int ExecMask = __builtin_amdgcn_read_exec();
  // Get the position of the thread in the current wavefront (1-index)
  const uint32_t LaneId = __lane_id() + 1;
  // Get the first active thread id inside this wavefront
  unsigned int FirstActiveThreadId = __ffsll(ExecMask);
  // Have only the first active thread perform the atomic add
  if (FirstActiveThreadId == LaneId) {
    atomicAdd(&InstructionExecutionCounts[InstructionId], 1);
  }

  // Calculate the LDS addresses accessed by this instruction
  unsigned int Address0 = M0 + VAddr + (Offset0 << 8);

  unsigned int Address1 = M0 + VAddr + (Offset1 << 8);
  // Calculate this work-item's bank IDs
  unsigned int BankIdx0 = getLDSBankIndex(Address0, CacheSizeLog2);
  unsigned int BankIdx1 = getLDSBankIndex(Address1, CacheSizeLog2);
  // Count how many other work-items in the warp have the same bank ID
  auto NumWorkItemsWithSameBankID0 =
      static_cast<float>(__popcll(__match_any(BankIdx0)));
  auto NumWorkItemsWithSameBankID1 =
      static_cast<float>(__popcll(__match_any(BankIdx1)));
  // We also have to count the conflict between BankIdx0 of
  // this thread and BankIdx1 of other threads
  for (uint32_t I = 0; I < 64; I++) {
    if (LaneId != I) {
      unsigned int BankIdx0IthThread = __shfl_sync(ExecMask, BankIdx0, I);
      if (BankIdx0IthThread == BankIdx1)
        NumWorkItemsWithSameBankID1++;
      unsigned int BankIdx1IthThread = __shfl_sync(ExecMask, BankIdx1, I);
      if (BankIdx1IthThread == BankIdx0)
        NumWorkItemsWithSameBankID0++;
    }
  }

  atomicAdd(&InstructionBankConflicts[InstructionId],
            getExtraBankConflictCount(NumWorkItemsWithSameBankID0));
  atomicAdd(&InstructionBankConflicts[InstructionId],
            getExtraBankConflictCount(NumWorkItemsWithSameBankID1));
}
LUTHIER_EXPORT_HOOK_HANDLE(countUniqueBanksPerWarpDoubleAddressTwoSource32);

LUTHIER_HOOK_ANNOTATE countUniqueBanksPerWarpDoubleAddressTwoSource64(
    uint32_t InstructionId, unsigned int M0, unsigned int VAddr,
    uint16_t Offset0, uint16_t Offset1, uint8_t CacheSizeLog2) {
  // Get the exec mask of the wavefront
  unsigned long long int ExecMask = __builtin_amdgcn_read_exec();
  // Get the position of the thread in the current wavefront (1-index)
  const uint32_t LaneId = __lane_id() + 1;
  // Get the first active thread id inside this wavefront
  unsigned int FirstActiveThreadId = __ffsll(ExecMask);
  // Have only the first active thread perform the atomic add
  if (FirstActiveThreadId == LaneId) {
    atomicAdd(&InstructionExecutionCounts[InstructionId], 1);
  }

  // Calculate the LDS addresses accessed by this instruction
  unsigned int Address0 = M0 + VAddr + (Offset0 << 9);

  unsigned int Address1 = M0 + VAddr + (Offset1 << 9);
  // Calculate this work-item's bank IDs
  unsigned int BankIdx0 = getLDSBankIndex(Address0, CacheSizeLog2);
  unsigned int BankIdx1 = getLDSBankIndex(Address1, CacheSizeLog2);
  // Count how many other work-items in the warp have the same bank ID
  auto NumWorkItemsWithSameBankID0 =
      static_cast<float>(__popcll(__match_any(BankIdx0)));
  auto NumWorkItemsWithSameBankID1 =
      static_cast<float>(__popcll(__match_any(BankIdx1)));
  // We also have to count the conflict between BankIdx0 of
  // this thread and BankIdx1 of other threads
  for (uint32_t I = 0; I < 64; I++) {
    if (LaneId != I) {
      unsigned int BankIdx0IthThread = __shfl_sync(ExecMask, BankIdx0, I);
      if (BankIdx0IthThread == BankIdx1)
        NumWorkItemsWithSameBankID1++;
      unsigned int BankIdx1IthThread = __shfl_sync(ExecMask, BankIdx1, I);
      if (BankIdx1IthThread == BankIdx0)
        NumWorkItemsWithSameBankID0++;
    }
  }

  atomicAdd(&InstructionBankConflicts[InstructionId],
            getExtraBankConflictCount(NumWorkItemsWithSameBankID0));
  atomicAdd(&InstructionBankConflicts[InstructionId],
            getExtraBankConflictCount(NumWorkItemsWithSameBankID1));
}

LUTHIER_EXPORT_HOOK_HANDLE(countUniqueBanksPerWarpDoubleAddressTwoSource64);

#endif // LUTHIER_LDS_HOST_ONLY

static llvm::Error instrumentSingleAddressDSOps(InstrumentationTask &IT,
                                                llvm::LLVMContext &Ctx,
                                                llvm::MachineInstr &MI,
                                                llvm::ConstantInt *InstId,
                                                llvm::ConstantInt *BankSize) {
  if (luthier::amdgpu::hasNamedOperand(MI.getOpcode(),
                                       llvm::AMDGPU::OpName::offset) &&
      luthier::amdgpu::hasNamedOperand(MI.getOpcode(),
                                       llvm::AMDGPU::OpName::addr)) {
    // Get the address operand of the LDS operation
    int AddrOpIdx = luthier::amdgpu::getNamedOperandIdx(
        MI.getOpcode(), llvm::AMDGPU::OpName::addr);
    llvm::MCRegister AddrOpVGPR = MI.getOperand(AddrOpIdx).getReg().asMCReg();
    // Get the offset of the operation
    int OffsetOpIdx = luthier::amdgpu::getNamedOperandIdx(
        MI.getOpcode(), llvm::AMDGPU::OpName::offset);
    unsigned Short = MI.getOperand(OffsetOpIdx).getImm();
    auto *ShortArg =
        llvm::ConstantInt::get(llvm::Type::getInt16Ty(Ctx), Short, false);
    LUTHIER_RETURN_ON_ERROR(
        IT.insertHookBefore(MI, llvm::StringRef("countUniqueBanksPerWarpSingleAddress"),
                            {InstId, llvm::AMDGPU::M0, AddrOpVGPR, ShortArg,
                             BankSize}));
  }
  return llvm::Error::success();
}

static llvm::Error instrumentDoubleAddressDSOps(InstrumentationTask &IT,
                                                llvm::LLVMContext &Ctx,
                                                llvm::MachineInstr &MI,
                                                llvm::ConstantInt *InstId,
                                                llvm::ConstantInt *BankSize) {
  if (luthier::amdgpu::hasNamedOperand(MI.getOpcode(),
                                       llvm::AMDGPU::OpName::offset0) &&
      luthier::amdgpu::hasNamedOperand(MI.getOpcode(),
                                       llvm::AMDGPU::OpName::offset1) &&
      luthier::amdgpu::hasNamedOperand(MI.getOpcode(),
                                       llvm::AMDGPU::OpName::addr)) {
    // Get the address operand of the LDS operation
    int AddrOpIdx = luthier::amdgpu::getNamedOperandIdx(
        MI.getOpcode(), llvm::AMDGPU::OpName::addr);
    llvm::MCRegister AddrOpVGPR = MI.getOperand(AddrOpIdx).getReg().asMCReg();
    // Get the offset of the operation
    int Offset0OpIdx = luthier::amdgpu::getNamedOperandIdx(
        MI.getOpcode(), llvm::AMDGPU::OpName::offset0);
    int Offset1OpIdx = luthier::amdgpu::getNamedOperandIdx(
        MI.getOpcode(), llvm::AMDGPU::OpName::offset1);
    if (MI.getOpcode() == llvm::AMDGPU::DS_READ2ST64_B32 ||
        MI.getOpcode() == llvm::AMDGPU::DS_WRITE2ST64_B32 ||
        MI.getOpcode() == llvm::AMDGPU::DS_WRXCHG2ST64_RTN_B32) {
      auto *Offset0Arg =
          llvm::ConstantInt::get(llvm::Type::getInt16Ty(Ctx),
                                 MI.getOperand(Offset0OpIdx).getImm(), false);
      auto *Offset1Arg =
          llvm::ConstantInt::get(llvm::Type::getInt16Ty(Ctx),
                                 MI.getOperand(Offset1OpIdx).getImm(), false);
      LUTHIER_RETURN_ON_ERROR(IT.insertHookBefore(
          MI, llvm::StringRef("countUniqueBanksPerWarpDoubleAddressTwoSource32"),
          {InstId, llvm::AMDGPU::M0, AddrOpVGPR, Offset0Arg, Offset1Arg,
           BankSize}));

    } else if (MI.getOpcode() == llvm::AMDGPU::DS_READ2ST64_B64 ||
               MI.getOpcode() == llvm::AMDGPU::DS_WRITE2ST64_B64 ||
               MI.getOpcode() == llvm::AMDGPU::DS_WRXCHG2ST64_RTN_B64) {
      auto *Offset0Arg =
          llvm::ConstantInt::get(llvm::Type::getInt16Ty(Ctx),
                                 MI.getOperand(Offset0OpIdx).getImm(), false);
      auto *Offset1Arg =
          llvm::ConstantInt::get(llvm::Type::getInt16Ty(Ctx),
                                 MI.getOperand(Offset1OpIdx).getImm(), false);
      LUTHIER_RETURN_ON_ERROR(IT.insertHookBefore(
          MI, llvm::StringRef("countUniqueBanksPerWarpDoubleAddressTwoSource64"),
          {InstId, llvm::AMDGPU::M0, AddrOpVGPR, Offset0Arg, Offset1Arg,
           BankSize}));
    } else {
      auto *Offset0Arg =
          llvm::ConstantInt::get(llvm::Type::getInt8Ty(Ctx),
                                 MI.getOperand(Offset0OpIdx).getImm(), false);
      auto *Offset1Arg =
          llvm::ConstantInt::get(llvm::Type::getInt8Ty(Ctx),
                                 MI.getOperand(Offset1OpIdx).getImm(), false);
      LUTHIER_RETURN_ON_ERROR(IT.insertHookBefore(
          MI, llvm::StringRef("countUniqueBanksPerWarpDoubleAddress"),
          {InstId, llvm::AMDGPU::M0, AddrOpVGPR, Offset0Arg, Offset1Arg,
           BankSize}));
    }
  }
  return llvm::Error::success();
}

static llvm::Error instrumentationLoop(InstrumentationTask &IT,
                                       LiftedRepresentation &LR,
                                       std::vector<InstrumentedLDSInstruction>
                                           &InstrumentedInstructions) {
  unsigned int I = 0;
  return LR.iterateAllDefinedFunctionTypes(
      [&](const hsa::LoadedCodeObjectSymbol &Sym,
          llvm::MachineFunction &MF) -> llvm::Error {
        for (auto &MBB : MF) {
          const auto &STI = MF.getSubtarget<llvm::GCNSubtarget>();
          const auto *TII = STI.getInstrInfo();
          auto &Ctx = LR.getContext();
          auto *BankSizeArg = llvm::ConstantInt::get(
              llvm::Type::getInt16Ty(Ctx), *Log2BankSize, false);
          for (auto &MI : MBB) {
            // Ignore instructions not inside an interval
            // Ignore GDS operations
            if (I >= *InstrBeginInterval && I < *InstrEndInterval &&
                luthier::amdgpu::isDS(MI) &&
                !luthier::amdgpu::isAlwaysGDS(*TII, MI.getOpcode()) &&
                !luthier::amdgpu::hasModifiersSet(*TII, MI,
                                                 llvm::AMDGPU::OpName::gds)) {
              LUTHIER_RETURN_ON_ERROR(LUTHIER_GENERIC_ERROR_CHECK(
                  InstrumentedInstructions.size() <
                      MaxTrackedLDSInstructions,
                  llvm::formatv("LDSBankConflict can track at most {0} LDS "
                                "instructions per kernel.",
                                MaxTrackedLDSInstructions)));

              auto InstId = InstrumentedInstructions.size();
              auto *InstIdArg = llvm::ConstantInt::get(
                  llvm::Type::getInt32Ty(Ctx), InstId, false);

              // Handle single source LDS access
              LUTHIER_RETURN_ON_ERROR(
                  instrumentSingleAddressDSOps(IT, Ctx, MI, InstIdArg,
                                               BankSizeArg));
              // Handle double source LDS access
              LUTHIER_RETURN_ON_ERROR(
                  instrumentDoubleAddressDSOps(IT, Ctx, MI, InstIdArg,
                                               BankSizeArg));
              std::string MIText;
              llvm::raw_string_ostream MIStream(MIText);
              MI.print(MIStream);
              InstrumentedInstructions.push_back(
                  {static_cast<unsigned>(InstId), I, std::string(MF.getName()),
                   std::string(TII->getName(MI.getOpcode())), MIStream.str()});
            }
            I++;
          }
        }
        return llvm::Error::success();
      });
}

static llvm::Expected<bool>
containsInstrumentableLDSInstructions(LiftedRepresentation &LR) {
  bool Found = false;
  unsigned int I = 0;
  LUTHIER_RETURN_ON_ERROR(LR.iterateAllDefinedFunctionTypes(
      [&](const hsa::LoadedCodeObjectSymbol &, llvm::MachineFunction &MF)
          -> llvm::Error {
        for (auto &MBB : MF) {
          const auto &STI = MF.getSubtarget<llvm::GCNSubtarget>();
          const auto *TII = STI.getInstrInfo();
          for (auto &MI : MBB) {
            if (I >= *InstrBeginInterval && I < *InstrEndInterval &&
                luthier::amdgpu::isDS(MI) &&
                !luthier::amdgpu::isAlwaysGDS(*TII, MI.getOpcode()) &&
                !luthier::amdgpu::hasModifiersSet(*TII, MI,
                                                  llvm::AMDGPU::OpName::gds)) {
              Found = true;
              return llvm::Error::success();
            }
            I++;
          }
          if (Found)
            return llvm::Error::success();
        }
        return llvm::Error::success();
      }));
  return Found;
}

static bool
instrumentAllFunctionsOfLR(const hsa::LoadedCodeObjectKernel &KernelSymbol) {
  auto LR = lift(KernelSymbol);
  LUTHIER_REPORT_FATAL_ON_ERROR(LR.takeError());
  auto HasLDS = containsInstrumentableLDSInstructions(
      const_cast<LiftedRepresentation &>(*LR));
  LUTHIER_REPORT_FATAL_ON_ERROR(HasLDS.takeError());
  if (!*HasLDS)
    return false;

  std::vector<InstrumentedLDSInstruction> InstrumentedInstructions;
  LUTHIER_REPORT_FATAL_ON_ERROR(instrumentAndLoad(
      KernelSymbol, *LR,
      [&](InstrumentationTask &IT, LiftedRepresentation &LR) {
        return instrumentationLoop(IT, LR, InstrumentedInstructions);
      },
      "lds bank conflict"));
  auto KernelName = KernelSymbol.getName();
  LUTHIER_REPORT_FATAL_ON_ERROR(KernelName.takeError());
  KernelInstructionMetadata[*KernelName] = std::move(InstrumentedInstructions);
  return true;
}

template <typename T> static llvm::Error zeroDeviceBuffer(T &DevBuffer) {
  T HostBuffer = 0;
  T *DevBufferAddr;
  const auto HsaCoreApiTable = C->getHsaCoreTable();

  LUTHIER_REPORT_FATAL_ON_ERROR(LUTHIER_HIP_CALL_ERROR_CHECK(
      HipRuntimeTableSnapshot->getTable()
          .callFunction<&::HipDispatchTable::hipGetSymbolAddress_fn>(
              (void **)&DevBufferAddr, &DevBuffer),
      "Failed to get the symbol associated with the device buffer"));
  return LUTHIER_HSA_CALL_ERROR_CHECK(
      HsaCoreApiTable.callFunction<hsa_memory_copy>(DevBufferAddr, &HostBuffer,
                                                    sizeof(T)),
      "Failed to copy zeros to the device buffer");
}

template <typename T>
static llvm::Expected<T> copyDeviceBufferToHost(T &DevBuffer) {
  T *DevBufferAddr;
  T HostBuffer;
  const auto HsaCoreApiTable = C->getHsaCoreTable();
  LUTHIER_REPORT_FATAL_ON_ERROR(LUTHIER_HIP_CALL_ERROR_CHECK(
      HipRuntimeTableSnapshot->getTable()
          .callFunction<&::HipDispatchTable::hipGetSymbolAddress_fn>(
              (void **)&DevBufferAddr, &DevBuffer),
      "Failed to get the symbol associated with the device buffer"));
  LUTHIER_RETURN_ON_ERROR(LUTHIER_HSA_CALL_ERROR_CHECK(
      HsaCoreApiTable.callFunction<hsa_memory_copy>(&HostBuffer, DevBufferAddr,
                                                    sizeof(T)),
      "Failed to copy the device buffer back to host"));
  return HostBuffer;
}

template <typename T, size_t N>
static llvm::Error zeroDeviceBuffer(T (&DevBuffer)[N]) {
  std::vector<T> HostBuffer(N, T{});
  T *DevBufferAddr;
  const auto HsaCoreApiTable = C->getHsaCoreTable();

  LUTHIER_REPORT_FATAL_ON_ERROR(LUTHIER_HIP_CALL_ERROR_CHECK(
      HipRuntimeTableSnapshot->getTable()
          .callFunction<&::HipDispatchTable::hipGetSymbolAddress_fn>(
              (void **)&DevBufferAddr, &DevBuffer),
      "Failed to get the symbol associated with the device buffer"));
  return LUTHIER_HSA_CALL_ERROR_CHECK(
      HsaCoreApiTable.callFunction<hsa_memory_copy>(
          DevBufferAddr, HostBuffer.data(), sizeof(T) * N),
      "Failed to copy zeros to the device buffer");
}

template <typename T, size_t N>
static llvm::Expected<std::vector<T>>
copyDeviceBufferToHost(T (&DevBuffer)[N]) {
  T *DevBufferAddr;
  std::vector<T> HostBuffer(N);
  const auto HsaCoreApiTable = C->getHsaCoreTable();
  LUTHIER_REPORT_FATAL_ON_ERROR(LUTHIER_HIP_CALL_ERROR_CHECK(
      HipRuntimeTableSnapshot->getTable()
          .callFunction<&::HipDispatchTable::hipGetSymbolAddress_fn>(
              (void **)&DevBufferAddr, &DevBuffer),
      "Failed to get the symbol associated with the device buffer"));
  LUTHIER_RETURN_ON_ERROR(LUTHIER_HSA_CALL_ERROR_CHECK(
      HsaCoreApiTable.callFunction<hsa_memory_copy>(
          HostBuffer.data(), DevBufferAddr, sizeof(T) * N),
      "Failed to copy the device buffer back to host"));
  return HostBuffer;
}

template <typename T>
static llvm::Error zeroDeviceArrayBySymbol(const void *Symbol, size_t Count) {
  std::vector<T> HostBuffer(Count, T{});
  T *DevBufferAddr;
  const auto HsaCoreApiTable = C->getHsaCoreTable();

  LUTHIER_REPORT_FATAL_ON_ERROR(LUTHIER_HIP_CALL_ERROR_CHECK(
      HipRuntimeTableSnapshot->getTable()
          .callFunction<&::HipDispatchTable::hipGetSymbolAddress_fn>(
              (void **)&DevBufferAddr, Symbol),
      "Failed to get the symbol associated with the device buffer"));
  return LUTHIER_HSA_CALL_ERROR_CHECK(
      HsaCoreApiTable.callFunction<hsa_memory_copy>(
          DevBufferAddr, HostBuffer.data(), sizeof(T) * Count),
      "Failed to copy zeros to the device buffer");
}

template <typename T>
static llvm::Expected<std::vector<T>>
copyDeviceArrayToHostBySymbol(const void *Symbol, size_t Count) {
  T *DevBufferAddr;
  std::vector<T> HostBuffer(Count);
  const auto HsaCoreApiTable = C->getHsaCoreTable();
  LUTHIER_REPORT_FATAL_ON_ERROR(LUTHIER_HIP_CALL_ERROR_CHECK(
      HipRuntimeTableSnapshot->getTable()
          .callFunction<&::HipDispatchTable::hipGetSymbolAddress_fn>(
              (void **)&DevBufferAddr, Symbol),
      "Failed to get the symbol associated with the device buffer"));
  LUTHIER_RETURN_ON_ERROR(LUTHIER_HSA_CALL_ERROR_CHECK(
      HsaCoreApiTable.callFunction<hsa_memory_copy>(
          HostBuffer.data(), DevBufferAddr, sizeof(T) * Count),
      "Failed to copy the device buffer back to host"));
  return HostBuffer;
}

static llvm::Expected<luthier::address_t>
getInstrumentationGlobalAddress(llvm::StringRef Name, hsa_agent_t Agent) {
  const auto &IM =
      luthier::ToolExecutableLoader::instance().getActiveInstrumentationModule();
  auto Address = IM.getGlobalVariablesLoadedOnAgent(Name, Agent);
  LUTHIER_RETURN_ON_ERROR(Address.takeError());
  if (!Address->has_value()) {
    return llvm::createStringError(
        std::errc::invalid_argument,
        "Instrumentation global %s is not loaded on the target agent.",
        Name.str().c_str());
  }
  return **Address;
}

template <typename T>
static llvm::Error zeroDeviceArrayByAddress(luthier::address_t Address,
                                            size_t Count) {
  std::vector<T> HostBuffer(Count, T{});
  const auto HsaCoreApiTable = C->getHsaCoreTable();
  return LUTHIER_HSA_CALL_ERROR_CHECK(
      HsaCoreApiTable.callFunction<hsa_memory_copy>(
          reinterpret_cast<void *>(Address), HostBuffer.data(),
          sizeof(T) * Count),
      "Failed to copy zeros to the device buffer");
}

template <typename T>
static llvm::Expected<std::vector<T>>
copyDeviceArrayToHostByAddress(luthier::address_t Address, size_t Count) {
  std::vector<T> HostBuffer(Count);
  const auto HsaCoreApiTable = C->getHsaCoreTable();
  LUTHIER_RETURN_ON_ERROR(LUTHIER_HSA_CALL_ERROR_CHECK(
      HsaCoreApiTable.callFunction<hsa_memory_copy>(
          HostBuffer.data(), reinterpret_cast<const void *>(Address),
          sizeof(T) * Count),
      "Failed to copy the device buffer back to host"));
  return HostBuffer;
}

static void
atPacketDispatchCallback(const hsa_queue_t &Queue, uint64_t PacketIdx,
                         llvm::ArrayRef<hsa::AqlPacket> Packets,
                         hsa_amd_queue_intercept_packet_writer PacketWriter) {
  // Copy the app packets because we are going to modify the packets field
  // of the argument, and it will be easier to mutate
  std::vector<hsa::AqlPacket> AppPackets(Packets);
  for (auto &Packet : AppPackets) {
    if (auto *DispatchPacket = Packet.asKernelDispatch()) {
      Mutex.lock();

      const auto HsaCoreApiTable = C->getHsaCoreTable();
      const auto HsaAmdExtTable = C->getHsaAmdExtTable();
      const auto &LoaderTable = C->getHsaLoaderTable();

      /// This is set to true if the original dispatch packet didn't have a
      /// signal field set. In this scenario, the tool creates a signal so that
      /// it can wait on the end of the kernel, and must destroy the signal
      /// after waiting on the kernel
      bool MustDestroySignalAfterLaunch{false};

      /// The value of the signal to wait for after kernel launches
      hsa_signal_value_t SignalValue{0};

      /// Keeps track of whether we are in the interval to profile or not
      bool ActiveRegion{false};

      /// If we are entering to a kernel launch:
      /// 1. Lock the mutex to prevent multiple kernels to run concurrently
      /// 2. Instrument the kernel if no already instrumented
      /// 3. Select whether the instrumented kernel will run or not
      /// 4. Reset the managed Counter variable
      // Get the kernel that is about to get launched
      std::unique_ptr<hsa::LoadedCodeObjectKernel> KernelBeingInstrumented;
      LUTHIER_REPORT_FATAL_ON_ERROR(
          hsa::KernelDescriptor::fromKernelObject(DispatchPacket->kernel_object)
              ->getLoadedCodeObjectKernelSymbol(HsaCoreApiTable, LoaderTable)
              .moveInto(KernelBeingInstrumented));

      auto KernelName = KernelBeingInstrumented->getName();
      LUTHIER_REPORT_FATAL_ON_ERROR(KernelName.takeError());
      auto KernelAgent = KernelBeingInstrumented->getAgent(LoaderTable);
      LUTHIER_REPORT_FATAL_ON_ERROR(KernelAgent.takeError());
#ifdef LUTHIER_LDS_HOST_ONLY
      LUTHIER_REPORT_FATAL_ON_ERROR(ensureDynamicModuleReady(*KernelAgent));
#endif
      std::string KernelNameToBePrinted = DemangleKernelNames
                                              ? llvm::demangle(*KernelName)
                                              : std::string(*KernelName);
      const bool KernelNameMatches =
          KernelNameFilter->empty() ||
          llvm::StringRef(*KernelName).contains(*KernelNameFilter) ||
          llvm::StringRef(KernelNameToBePrinted).contains(*KernelNameFilter);
      if (KernelNameMatches && NumKernelLaunched >= *KernelBeginInterval &&
          NumKernelLaunched < *KernelEndInterval) {
        ActiveRegion = true;
      } else {
        ActiveRegion = false;
      }

      if (!ActiveRegion) {
        PacketWriter(DispatchPacket, 1);
        NumKernelLaunched++;
        Mutex.unlock();
        continue;
      }

      auto IsKernelInstrumented =
          isKernelInstrumented(*KernelBeingInstrumented, "lds bank conflict");
      LUTHIER_REPORT_FATAL_ON_ERROR(IsKernelInstrumented.takeError());
      bool ShouldLaunchInstrumented = *IsKernelInstrumented;
      if (!*IsKernelInstrumented) {

        ShouldLaunchInstrumented =
            instrumentAllFunctionsOfLR(*KernelBeingInstrumented);
      }

      if (!ShouldLaunchInstrumented) {
        PacketWriter(DispatchPacket, 1);
        NumKernelLaunched++;
        Mutex.unlock();
        continue;
      }

      luthier::errs() << "Kernel " << KernelNameToBePrinted
                      << " is being launched\n";
      luthier::errs() << "Kernel is being instrumented.\n";

      LUTHIER_REPORT_FATAL_ON_ERROR(luthier::overrideWithInstrumented(
          *DispatchPacket, "lds bank conflict"));

      // Zero the device variables

      auto BankConflictsAddress = getInstrumentationGlobalAddress(
          "InstructionBankConflicts", *KernelAgent);
      LUTHIER_REPORT_FATAL_ON_ERROR(BankConflictsAddress.takeError());
      LUTHIER_REPORT_FATAL_ON_ERROR(zeroDeviceArrayByAddress<float>(
          *BankConflictsAddress, MaxTrackedLDSInstructions));

      auto ExecutionCountsAddress = getInstrumentationGlobalAddress(
          "InstructionExecutionCounts", *KernelAgent);
      LUTHIER_REPORT_FATAL_ON_ERROR(ExecutionCountsAddress.takeError());
      LUTHIER_REPORT_FATAL_ON_ERROR(zeroDeviceArrayByAddress<uint64_t>(
          *ExecutionCountsAddress, MaxTrackedLDSInstructions));

      // Get the packet's completion signal and its value. Only profiled kernels
      // are serialized so setup/no-LDS kernels can pass through at full speed.
      if (DispatchPacket->completion_signal.handle == 0) {
        if (HsaAmdExtTable.callFunction<hsa_amd_signal_create>(
                SignalValue, 0, nullptr, 0,
                &DispatchPacket->completion_signal) != HSA_STATUS_SUCCESS)
          llvm::report_fatal_error("Failed to create a signal for the "
                                   "dispatch packet.");
        MustDestroySignalAfterLaunch = true;
      } else {
        MustDestroySignalAfterLaunch = false;
      }
      SignalValue = HsaCoreApiTable.callFunction<hsa_signal_load_scacquire>(
          DispatchPacket->completion_signal);

      constexpr auto Timeout =
          std::chrono::duration_cast<std::chrono::nanoseconds>(
              std::chrono::seconds{300})
              .count();
      PacketWriter(DispatchPacket, 1);
      auto CurrentSignalValue =
          HsaCoreApiTable.callFunction<hsa_signal_wait_relaxed>(
              DispatchPacket->completion_signal, HSA_SIGNAL_CONDITION_LT,
              SignalValue, Timeout, HSA_WAIT_STATE_ACTIVE);
      if (CurrentSignalValue >= SignalValue)
        llvm::report_fatal_error(
            llvm::formatv("Wait timeout reached for signal handle {0:x},"
                          "Expected "
                          "value: {1}, Actual Value: {2}",
                          DispatchPacket->completion_signal.handle,
                          CurrentSignalValue - 1, SignalValue));
      if (MustDestroySignalAfterLaunch) {
        if (HsaCoreApiTable.callFunction<hsa_signal_destroy>(
                DispatchPacket->completion_signal) != HSA_STATUS_SUCCESS) {
          llvm::report_fatal_error("Failed to destroy the completed kernel's"
                                   "signal");
        }
      }
      {
        luthier::errs() << "Kernel is being waited on\n";
        /// If we are exiting a kernel launch:
        /// 1. Wait on the signal of the kernel being launched
        /// 2. Get the number of wave fronts in the kernel
        /// 3. Print the counter for this kernel
        /// 4. Release the lock

        // Get the kernel that was launched

        auto KernelName = KernelBeingInstrumented->getName();
        LUTHIER_REPORT_FATAL_ON_ERROR(KernelName.takeError());
        std::string KernelNameToBePrinted = DemangleKernelNames
                                                ? llvm::demangle(*KernelName)
                                                : std::string(*KernelName);

        auto BankConflictsAddress = getInstrumentationGlobalAddress(
            "InstructionBankConflicts", *KernelAgent);
        LUTHIER_REPORT_FATAL_ON_ERROR(BankConflictsAddress.takeError());
        auto KernelInstructionConflicts = copyDeviceArrayToHostByAddress<float>(
            *BankConflictsAddress, MaxTrackedLDSInstructions);
        LUTHIER_REPORT_FATAL_ON_ERROR(KernelInstructionConflicts.takeError());

        auto ExecutionCountsAddress = getInstrumentationGlobalAddress(
            "InstructionExecutionCounts", *KernelAgent);
        LUTHIER_REPORT_FATAL_ON_ERROR(ExecutionCountsAddress.takeError());
        auto KernelInstructionExecutions =
            copyDeviceArrayToHostByAddress<uint64_t>(
                *ExecutionCountsAddress, MaxTrackedLDSInstructions);
        LUTHIER_REPORT_FATAL_ON_ERROR(KernelInstructionExecutions.takeError());

        auto MetadataIt = KernelInstructionMetadata.find(*KernelName);
        luthier::errs() << llvm::formatv(
            "Kernel {0} - {1}: Grid=({2}, {3}, {4}) Workgroup=({5}, {6}, {7}) "
            "DynLDS={8}\n",
            NumKernelLaunched, KernelNameToBePrinted,
            DispatchPacket->grid_size_x, DispatchPacket->grid_size_y,
            DispatchPacket->grid_size_z, DispatchPacket->workgroup_size_x,
            DispatchPacket->workgroup_size_y, DispatchPacket->workgroup_size_z,
            DispatchPacket->group_segment_size);
        if (MetadataIt == KernelInstructionMetadata.end()) {
          luthier::errs() << "  No instruction metadata found.\n";
        } else {
          for (const auto &Inst : MetadataIt->second) {
            luthier::errs() << llvm::formatv(
                "  LDS inst {0} (global-mi={1}, function={2}, opcode={3}): "
                "executions={4}, bank-conflicts={5:F2}\n",
                Inst.Id, Inst.GlobalInstructionIndex, Inst.FunctionName,
                Inst.OpcodeName, (*KernelInstructionExecutions)[Inst.Id],
                (*KernelInstructionConflicts)[Inst.Id]);
            luthier::errs() << "    " << Inst.MachineInstr;
          }
        }
      }
      NumKernelLaunched++;
      Mutex.unlock();
    } else {
      PacketWriter(&Packet, 1);
    }
  }
}

namespace luthier {

static void initializeRuntimeContext() {
  static std::once_flag RuntimeOnce{};
  std::call_once(RuntimeOnce, []() {
    setenv("LUTHIER_DISABLE_STATIC_IMODULE", "1", 0);
    llvm::Error Err = llvm::Error::success();
    C = new Context(atPacketDispatchCallback, Err);
    if (Err)
      llvm::report_fatal_error(std::move(Err));
    luthier::ToolExecutableLoader::instance().useDynamicInstrumentationModule();
    HipRuntimeTableSnapshot =
        new rocprofiler::HipApiTableSnapshot<ROCPROFILER_HIP_RUNTIME_TABLE>(
            Err);
    if (Err)
      llvm::report_fatal_error(std::move(Err));
  });
}

void atToolFini(void *) {
  static std::once_flag Once{};
  std::call_once(Once, []() {
    const char *DestroyOnFini = std::getenv("LUTHIER_DESTROY_ON_FINI");
    if (DestroyOnFini == nullptr ||
        !llvm::StringRef(DestroyOnFini).equals_insensitive("1")) {
      // Keep rocprofiler/HSA wrappers alive until process teardown finishes.
      // Destroying them while HIP is finalizing can leave shutdown code using
      // stale API-table state in large apps such as llama.cpp.
      return;
    }

    delete C;

    delete HipRuntimeTableSnapshot;

    delete InstrBeginInterval;

    delete InstrEndInterval;

    delete KernelBeginInterval;

    delete KernelEndInterval;

    delete DemangleKernelNames;

    delete Log2BankSize;

    delete KernelNameFilter;

    delete LDSBankConflictToolOptionCategory;
  });
}

static void atToolFiniNoArgs();

void atToolInit(void *) {
  static std::once_flag Once{};
  std::call_once(Once, [] {
    luthier::errs() << "LDS Bank Conflict detection tool is launching.\n";

    // ROCprofiler-sdk's COMGR path is unstable with HIP deferred module
    // loading in large apps such as llama.cpp. Eager loading avoids the crash
    // and keeps code-object storage available for Luthier's lazy cache.
    setenv("HIP_ENABLE_DEFERRED_LOADING", "0", 1);

    LDSBankConflictToolOptionCategory =
        new llvm::cl::OptionCategory("LDS Bank Conflict Options");

    InstrBeginInterval = new llvm::cl::opt<unsigned int>(
        "instr-begin-interval",
        llvm::cl::desc("Beginning of the instruction interval where to "
                       "apply instrumentation, inclusive"),
        llvm::cl::init(0), llvm::cl::NotHidden,
        llvm::cl::cat(*LDSBankConflictToolOptionCategory));

    InstrEndInterval = new llvm::cl::opt<unsigned int>(
        "instr-end-interval",
        llvm::cl::desc("End of the instruction interval where to apply "
                       "instrumentation, inclusive"),
        llvm::cl::init(std::numeric_limits<unsigned int>::max()),
        llvm::cl::NotHidden, llvm::cl::cat(*LDSBankConflictToolOptionCategory));

    KernelBeginInterval = new llvm::cl::opt<unsigned int>(
        "kernel-start-interval",
        llvm::cl::desc("Beginning of the kernel interval to apply "
                       "instrumentation, inclusive"),
        llvm::cl::init(0), llvm::cl::NotHidden,
        llvm::cl::cat(*LDSBankConflictToolOptionCategory));

    KernelEndInterval = new llvm::cl::opt<unsigned int>(
        "kernel-end-interval",
        llvm::cl::desc(
            "End of the kernel interval to apply instrumentation, exclusive"),
        llvm::cl::init(std::numeric_limits<unsigned int>::max()),
        llvm::cl::NotHidden, llvm::cl::cat(*LDSBankConflictToolOptionCategory));

    DemangleKernelNames = new llvm::cl::opt<bool>(
        "demangle-kernel-names",
        llvm::cl::desc("Whether to demangle kernel names before printing"),
        llvm::cl::init(true), llvm::cl::NotHidden,
        llvm::cl::cat(*LDSBankConflictToolOptionCategory));

    Log2BankSize = new llvm::cl::opt<unsigned>(
        "log-two-bank-size", llvm::cl::desc("Log2 of the LDS bank size"),
        llvm::cl::init(2), llvm::cl::NotHidden,
        llvm::cl::cat(*LDSBankConflictToolOptionCategory));

    KernelNameFilter = new llvm::cl::opt<std::string>(
        "kernel-name-filter",
        llvm::cl::desc("Only instrument kernels whose mangled or demangled "
                       "name contains this substring"),
        llvm::cl::init(""), llvm::cl::NotHidden,
        llvm::cl::cat(*LDSBankConflictToolOptionCategory));

    const auto Argv = "";
    // LLVM 23 inserted a vfs::FileSystem *VFS parameter into
    // ParseCommandLineOptions between the error stream and the env-var name.
    // Pass nullptr to keep the default real-filesystem behaviour.
    LUTHIER_REPORT_FATAL_ON_ERROR(LUTHIER_GENERIC_ERROR_CHECK(
        llvm::cl::ParseCommandLineOptions(
            0, &Argv, "Luthier ROCm Instruction Counter Tool", &luthier::errs(),
            /*VFS=*/nullptr, "LUTHIER_ARGS"),
        "Failed to parse the command line arguments."));
    llvm::EnablePrettyStackTrace();
    llvm::sys::PrintStackTraceOnErrorSignal(llvm::StringRef());
    llvm::setBugReportMsg("PLEASE submit a bug report to "
                          "https://github.com/matinraayai/Luthier/issues/ and "
                          "include the crash error message and backtrace.\n");
    // Add the rocprofiler finalize function as a signal handler to LLVM so that
    // it executes in case of a fatal error
    llvm::sys::AddSignalHandler(atToolFini, nullptr);

    unsigned DeferredInitMs = 0;
    if (const char *DeferredInitEnv =
            std::getenv("LUTHIER_DEFER_CONTEXT_INIT_MS")) {
      llvm::StringRef(DeferredInitEnv).getAsInteger(10, DeferredInitMs);
    }
    if (DeferredInitMs == 0) {
      initializeRuntimeContext();
    } else {
      std::thread([DeferredInitMs]() {
        std::this_thread::sleep_for(std::chrono::milliseconds(DeferredInitMs));
        initializeRuntimeContext();
      }).detach();
    }
  });
}

static void atToolFiniNoArgs() { atToolFini(nullptr); }

static int atRocprofilerToolInit(rocprofiler_client_finalize_t, void *Data) {
  atToolInit(Data);
  return 0;
}

} // namespace luthier

extern "C" __attribute__((used)) rocprofiler_tool_configure_result_t *
rocprofiler_configure(uint32_t Version, const char *RuntimeVersion,
                      uint32_t Priority, rocprofiler_client_id_t *ClientID) {
  LLVM_DEBUG(const uint32_t RocProfVerMajor = Version / 10000;
             const uint32_t RocProfVerMinor = (Version % 10000) / 100;
             const uint32_t RocProfVerPatch = Version % 100;
             llvm::dbgs() << "Registering Luthier tool with rocprofiler-sdk.\n";
             llvm::dbgs() << "Rocprofiler-sdk version: " << RocProfVerMajor
                          << "." << RocProfVerMinor << "." << RocProfVerPatch
                          << " (" << RuntimeVersion << ")"
                          << "\n";
             llvm::dbgs() << "Tool priority: " << Priority << ";\n";);
  ClientID->name = "Luthier LDS Bank Conflict tool";

  static auto Cfg = rocprofiler_tool_configure_result_t{
      sizeof(rocprofiler_tool_configure_result_t),
      &luthier::atRocprofilerToolInit,
      &luthier::atToolFini, nullptr};
  return &Cfg;
}
