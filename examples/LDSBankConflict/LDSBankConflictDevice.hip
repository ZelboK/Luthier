#define HIP_ENABLE_WARP_SYNC_BUILTINS

#include <cstdint>
#include <hip/hip_runtime.h>
#include <luthier/luthier.h>

using namespace luthier;

static constexpr unsigned MaxTrackedLDSInstructions = 65536;

extern "C" __attribute__((device, visibility("default"))) float
    InstructionBankConflicts[MaxTrackedLDSInstructions] = {};

extern "C" __attribute__((device, visibility("default"))) uint64_t
    InstructionExecutionCounts[MaxTrackedLDSInstructions] = {};

extern "C" __attribute__((used, visibility("default"))) void
    *InstructionBankConflictsHostSymbol = &InstructionBankConflicts;

extern "C" __attribute__((used, visibility("default"))) void
    *InstructionExecutionCountsHostSymbol = &InstructionExecutionCounts;

MARK_LUTHIER_DEVICE_MODULE

__device__ static float getExtraBankConflictCount(float WorkItemsWithSameBank) {
  return (WorkItemsWithSameBank - 1.f) / WorkItemsWithSameBank;
}

__device__ static unsigned getLDSBankIndex(unsigned Address,
                                           unsigned CacheSizeLog2) {
  return (Address >> CacheSizeLog2) & 31u;
}

LUTHIER_HOOK_ANNOTATE
countUniqueBanksPerWarpSingleAddress(uint32_t InstructionId, unsigned int M0,
                                     unsigned int VAddr, short Offset,
                                     short CacheSizeLog2) {
  unsigned long long int ExecMask = __builtin_amdgcn_read_exec();
  const uint32_t LaneId = __lane_id() + 1;
  unsigned int FirstActiveThreadId = __ffsll(ExecMask);
  if (FirstActiveThreadId == LaneId)
    atomicAdd(&InstructionExecutionCounts[InstructionId], 1);

  unsigned int Address = M0 + VAddr + Offset;
  unsigned int BankIdx = getLDSBankIndex(Address, CacheSizeLog2);
  auto NumWorkItemsWithSameBankID =
      static_cast<float>(__popcll(__match_any(BankIdx)));
  atomicAdd(&InstructionBankConflicts[InstructionId],
            getExtraBankConflictCount(NumWorkItemsWithSameBankID));
}

LUTHIER_EXPORT_HOOK_HANDLE(countUniqueBanksPerWarpSingleAddress);

LUTHIER_HOOK_ANNOTATE
countUniqueBanksPerWarpDoubleAddress(uint32_t InstructionId, unsigned int M0,
                                     unsigned int VAddr, uint8_t Offset0,
                                     uint8_t Offset1, short CacheSizeLog2) {
  unsigned long long int ExecMask = __builtin_amdgcn_read_exec();
  const uint32_t LaneId = __lane_id() + 1;
  unsigned int FirstActiveThreadId = __ffsll(ExecMask);
  if (FirstActiveThreadId == LaneId)
    atomicAdd(&InstructionExecutionCounts[InstructionId], 1);

  unsigned int Address0 = M0 + VAddr + (Offset0 << 2);
  unsigned int Address1 = M0 + VAddr + (Offset1 << 2);
  unsigned int BankIdx0 = getLDSBankIndex(Address0, CacheSizeLog2);
  unsigned int BankIdx1 = getLDSBankIndex(Address1, CacheSizeLog2);
  auto NumWorkItemsWithSameBankID0 =
      static_cast<float>(__popcll(__match_any(BankIdx0)));
  auto NumWorkItemsWithSameBankID1 =
      static_cast<float>(__popcll(__match_any(BankIdx1)));
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
  unsigned long long int ExecMask = __builtin_amdgcn_read_exec();
  const uint32_t LaneId = __lane_id() + 1;
  unsigned int FirstActiveThreadId = __ffsll(ExecMask);
  if (FirstActiveThreadId == LaneId)
    atomicAdd(&InstructionExecutionCounts[InstructionId], 1);

  unsigned int Address0 = M0 + VAddr + (Offset0 << 8);
  unsigned int Address1 = M0 + VAddr + (Offset1 << 8);
  unsigned int BankIdx0 = getLDSBankIndex(Address0, CacheSizeLog2);
  unsigned int BankIdx1 = getLDSBankIndex(Address1, CacheSizeLog2);
  auto NumWorkItemsWithSameBankID0 =
      static_cast<float>(__popcll(__match_any(BankIdx0)));
  auto NumWorkItemsWithSameBankID1 =
      static_cast<float>(__popcll(__match_any(BankIdx1)));
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
  unsigned long long int ExecMask = __builtin_amdgcn_read_exec();
  const uint32_t LaneId = __lane_id() + 1;
  unsigned int FirstActiveThreadId = __ffsll(ExecMask);
  if (FirstActiveThreadId == LaneId)
    atomicAdd(&InstructionExecutionCounts[InstructionId], 1);

  unsigned int Address0 = M0 + VAddr + (Offset0 << 9);
  unsigned int Address1 = M0 + VAddr + (Offset1 << 9);
  unsigned int BankIdx0 = getLDSBankIndex(Address0, CacheSizeLog2);
  unsigned int BankIdx1 = getLDSBankIndex(Address1, CacheSizeLog2);
  auto NumWorkItemsWithSameBankID0 =
      static_cast<float>(__popcll(__match_any(BankIdx0)));
  auto NumWorkItemsWithSameBankID1 =
      static_cast<float>(__popcll(__match_any(BankIdx1)));
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
