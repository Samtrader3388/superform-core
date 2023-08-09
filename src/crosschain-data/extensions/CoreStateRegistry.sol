// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

import {IERC20} from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseStateRegistry} from "../BaseStateRegistry.sol";
import {LiquidityHandler} from "../../crosschain-liquidity/LiquidityHandler.sol";
import {ISuperPositions} from "../../interfaces/ISuperPositions.sol";
import {ICoreStateRegistry} from "../../interfaces/ICoreStateRegistry.sol";
import {ISuperRegistry} from "../../interfaces/ISuperRegistry.sol";
import {IQuorumManager} from "../../interfaces/IQuorumManager.sol";
import {IBaseForm} from "../../interfaces/IBaseForm.sol";
import {IBridgeValidator} from "../../interfaces/IBridgeValidator.sol";
import {PayloadState, TransactionType, CallbackType, AMBMessage, InitSingleVaultData, InitMultiVaultData, AckAMBData, AMBExtraData, ReturnMultiData, ReturnSingleData} from "../../types/DataTypes.sol";
import {LiqRequest} from "../../types/DataTypes.sol";
import {ISuperRBAC} from "../../interfaces/ISuperRBAC.sol";
import {DataLib} from "../../libraries/DataLib.sol";
import {PayloadUpdaterLib} from "../../libraries/PayloadUpdaterLib.sol";
import {Error} from "../../utils/Error.sol";

/// @title CoreStateRegistry
/// @author Zeropoint Labs
/// @dev enables communication between Superform Core Contracts deployed on all supported networks
contract CoreStateRegistry is LiquidityHandler, BaseStateRegistry, ICoreStateRegistry {
    using SafeERC20 for IERC20;
    using DataLib for uint256;

    /*///////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev just stores the superFormIds that failed in a specific payload id
    mapping(uint256 payloadId => uint256[] superFormIds) internal failedDeposits;

    /*///////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlySender() override {
        if (!ISuperRBAC(superRegistry.superRBAC()).hasCoreContractsRole(msg.sender)) revert Error.NOT_CORE_CONTRACTS();
        _;
    }

    modifier isValidPayloadId(uint256 payloadId_) {
        if (payloadId_ > payloadsCount) {
            revert Error.INVALID_PAYLOAD_ID();
        }
        _;
    }

    /*///////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(ISuperRegistry superRegistry_) BaseStateRegistry(superRegistry_) {}

    /*///////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    struct UpdateDepositPayloadVars {
        bytes32 previousPayloadProof_;
        bytes previousPayloadBody_;
        uint256 previousPayloadHeader_;
        InitSingleVaultData singleVaultData;
        uint64 srcChainId;
        uint256 l1;
        uint256 l2;
    }

    /// @inheritdoc ICoreStateRegistry
    function updateMultiVaultDepositPayload(
        uint256 payloadId_,
        uint256[] calldata finalAmounts_
    ) external virtual override onlyUpdater isValidPayloadId(payloadId_) {
        UpdateDepositPayloadVars memory v_;

        /// @dev load header and body of payload
        v_.previousPayloadHeader_ = payloadHeader[payloadId_];
        v_.previousPayloadBody_ = payloadBody[payloadId_];

        v_.previousPayloadProof_ = keccak256(
            abi.encode(AMBMessage(v_.previousPayloadHeader_, v_.previousPayloadBody_))
        );

        InitMultiVaultData memory multiVaultData = abi.decode(v_.previousPayloadBody_, (InitMultiVaultData));

        (, , , , , v_.srcChainId) = v_.previousPayloadHeader_.decodeTxInfo();

        if (messageQuorum[v_.previousPayloadProof_] < getRequiredMessagingQuorum(v_.srcChainId)) {
            revert Error.QUORUM_NOT_REACHED();
        }

        v_.l1 = multiVaultData.amounts.length;
        v_.l2 = finalAmounts_.length;

        /// @dev compare number of vaults to update with provided finalAmounts length
        if (v_.l1 != v_.l2) {
            revert Error.DIFFERENT_PAYLOAD_UPDATE_AMOUNTS_LENGTH();
        }

        /// @dev validate payload update
        PayloadUpdaterLib.validateDepositPayloadUpdate(v_.previousPayloadHeader_, payloadTracking[payloadId_], 1);
        PayloadUpdaterLib.validateSlippageArray(finalAmounts_, multiVaultData.amounts, multiVaultData.maxSlippage);

        multiVaultData.amounts = finalAmounts_;

        /// @dev re-set previous message quorum to 0
        delete messageQuorum[v_.previousPayloadProof_];

        payloadBody[payloadId_] = abi.encode(multiVaultData);

        /// @dev set new message quorum
        messageQuorum[
            keccak256(abi.encode(AMBMessage(v_.previousPayloadHeader_, payloadBody[payloadId_])))
        ] = getRequiredMessagingQuorum(v_.srcChainId);

        /// @dev define the payload status as updated
        payloadTracking[payloadId_] = PayloadState.UPDATED;

        emit PayloadUpdated(payloadId_);
    }

    /// @inheritdoc ICoreStateRegistry
    function updateSingleVaultDepositPayload(
        uint256 payloadId_,
        uint256 finalAmount_
    ) external virtual override onlyUpdater isValidPayloadId(payloadId_) {
        /// @dev load header and body of payload
        bytes memory previousPayloadBody_ = payloadBody[payloadId_];
        uint256 previousPayloadHeader_ = payloadHeader[payloadId_];
        InitSingleVaultData memory singleVaultData = abi.decode(previousPayloadBody_, (InitSingleVaultData));

        bytes32 previousPayloadProof_ = keccak256(abi.encode(AMBMessage(previousPayloadHeader_, previousPayloadBody_)));

        (, , , , , uint64 srcChainId) = previousPayloadHeader_.decodeTxInfo();
        if (messageQuorum[previousPayloadProof_] < getRequiredMessagingQuorum(srcChainId)) {
            revert Error.QUORUM_NOT_REACHED();
        }

        /// @dev validate payload update
        PayloadUpdaterLib.validateDepositPayloadUpdate(previousPayloadHeader_, payloadTracking[payloadId_], 0);
        PayloadUpdaterLib.validateSlippage(finalAmount_, singleVaultData.amount, singleVaultData.maxSlippage);

        delete messageQuorum[previousPayloadProof_];

        singleVaultData.amount = finalAmount_;

        payloadBody[payloadId_] = abi.encode(singleVaultData);

        /// @dev set new message quorum
        messageQuorum[
            keccak256(abi.encode(AMBMessage(previousPayloadHeader_, payloadBody[payloadId_])))
        ] = getRequiredMessagingQuorum(srcChainId);

        payloadTracking[payloadId_] = PayloadState.UPDATED;

        emit PayloadUpdated(payloadId_);
    }

    struct UpdateWithdrawPayloadVars {
        bytes32 previousPayloadProof_;
        bytes previousPayloadBody_;
        uint256 previousPayloadHeader_;
        InitSingleVaultData singleVaultData;
        uint64 srcChainId;
        uint64 dstChainId;
        uint256 l1;
        uint256 l2;
        address srcSender;
    }

    /// @inheritdoc ICoreStateRegistry
    function updateMultiVaultWithdrawPayload(
        uint256 payloadId_,
        bytes[] calldata txData_
    ) external virtual override onlyUpdater isValidPayloadId(payloadId_) {
        UpdateWithdrawPayloadVars memory v_;

        /// @dev load header and body of payload
        v_.previousPayloadHeader_ = payloadHeader[payloadId_];
        v_.previousPayloadBody_ = payloadBody[payloadId_];

        v_.previousPayloadProof_ = keccak256(
            abi.encode(AMBMessage(v_.previousPayloadHeader_, v_.previousPayloadBody_))
        );

        InitMultiVaultData memory multiVaultData = abi.decode(v_.previousPayloadBody_, (InitMultiVaultData));

        (, , , , v_.srcSender, v_.srcChainId) = v_.previousPayloadHeader_.decodeTxInfo();

        if (messageQuorum[v_.previousPayloadProof_] < getRequiredMessagingQuorum(v_.srcChainId)) {
            revert Error.QUORUM_NOT_REACHED();
        }

        v_.l1 = multiVaultData.liqData.length;
        v_.l2 = txData_.length;

        if (v_.l1 != v_.l2) {
            revert Error.DIFFERENT_PAYLOAD_UPDATE_TX_DATA_LENGTH();
        }

        /// @dev validate payload update
        PayloadUpdaterLib.validateWithdrawPayloadUpdate(v_.previousPayloadHeader_, payloadTracking[payloadId_], 1);

        v_.dstChainId = superRegistry.chainId();

        /// @dev validates if the incoming update is valid
        for (uint256 i; i < v_.l1; ) {
            if (txData_[i].length != 0 && multiVaultData.liqData[i].txData.length == 0) {
                (address superform, , ) = multiVaultData.superFormIds[i].getSuperform();

                PayloadUpdaterLib.validateLiqReq(multiVaultData.liqData[i]);
                IBridgeValidator(superRegistry.getBridgeValidator(multiVaultData.liqData[i].bridgeId)).validateTxData(
                    txData_[i],
                    v_.dstChainId,
                    v_.srcChainId,
                    false,
                    superform,
                    v_.srcSender,
                    multiVaultData.liqData[i].token
                );

                multiVaultData.liqData[i].txData = txData_[i];
            }

            unchecked {
                ++i;
            }
        }

        /// @dev re-set previous message quorum to 0
        delete messageQuorum[v_.previousPayloadProof_];

        payloadBody[payloadId_] = abi.encode(multiVaultData);

        /// @dev set new message quorum
        messageQuorum[
            keccak256(abi.encode(AMBMessage(v_.previousPayloadHeader_, payloadBody[payloadId_])))
        ] = getRequiredMessagingQuorum(v_.srcChainId);

        /// @dev define the payload status as updated
        payloadTracking[payloadId_] = PayloadState.UPDATED;

        emit PayloadUpdated(payloadId_);
    }

    /// @inheritdoc ICoreStateRegistry
    function updateSingleVaultWithdrawPayload(
        uint256 payloadId_,
        bytes calldata txData_
    ) external virtual override onlyUpdater isValidPayloadId(payloadId_) {
        UpdateWithdrawPayloadVars memory v_;

        /// @dev load header and body of the payload
        v_.previousPayloadBody_ = payloadBody[payloadId_];
        v_.previousPayloadHeader_ = payloadHeader[payloadId_];
        InitSingleVaultData memory singleVaultData = abi.decode(v_.previousPayloadBody_, (InitSingleVaultData));

        v_.previousPayloadProof_ = keccak256(
            abi.encode(AMBMessage(v_.previousPayloadHeader_, v_.previousPayloadBody_))
        );

        (, , , , v_.srcSender, v_.srcChainId) = v_.previousPayloadHeader_.decodeTxInfo();
        if (messageQuorum[v_.previousPayloadProof_] < getRequiredMessagingQuorum(v_.srcChainId)) {
            revert Error.QUORUM_NOT_REACHED();
        }

        /// @dev validate payload update
        PayloadUpdaterLib.validateWithdrawPayloadUpdate(v_.previousPayloadHeader_, payloadTracking[payloadId_], 0);
        PayloadUpdaterLib.validateLiqReq(singleVaultData.liqData);

        (address superform, , ) = singleVaultData.superFormId.getSuperform();

        IBridgeValidator(superRegistry.getBridgeValidator(singleVaultData.liqData.bridgeId)).validateTxData(
            txData_,
            superRegistry.chainId(),
            v_.srcChainId,
            false,
            superform,
            v_.srcSender,
            singleVaultData.liqData.token
        );

        delete messageQuorum[v_.previousPayloadProof_];

        singleVaultData.liqData.txData = txData_;

        payloadBody[payloadId_] = abi.encode(singleVaultData);

        /// @dev set new message quorum
        messageQuorum[
            keccak256(abi.encode(AMBMessage(v_.previousPayloadHeader_, payloadBody[payloadId_])))
        ] = getRequiredMessagingQuorum(v_.srcChainId);

        payloadTracking[payloadId_] = PayloadState.UPDATED;
        emit PayloadUpdated(payloadId_);
    }

    /// @dev local struct to avoid stack too deep errors
    struct CoreProcessPayloadLocalVars {
        bytes _payloadBody;
        uint256 _payloadHeader;
        uint8 txType;
        uint8 callbackType;
        uint8 multi;
        address srcSender;
        uint64 srcChainId;
        AMBMessage _message;
        bytes returnMessage;
        bytes32 _proof;
    }

    /// @inheritdoc BaseStateRegistry
    function processPayload(
        uint256 payloadId_,
        bytes memory ackExtraData_
    )
        external
        payable
        virtual
        override
        onlyProcessor
        isValidPayloadId(payloadId_)
        returns (bytes memory savedMessage, bytes memory returnMessage)
    {
        CoreProcessPayloadLocalVars memory v;

        v._payloadBody = payloadBody[payloadId_];
        v._payloadHeader = payloadHeader[payloadId_];

        if (payloadTracking[payloadId_] == PayloadState.PROCESSED) {
            revert Error.PAYLOAD_ALREADY_PROCESSED();
        }

        (v.txType, v.callbackType, v.multi, , v.srcSender, v.srcChainId) = v._payloadHeader.decodeTxInfo();

        v._message = AMBMessage(v._payloadHeader, v._payloadBody);

        savedMessage = abi.encode(v._message);

        /// @dev validates quorum
        v._proof = keccak256(savedMessage);

        /// @dev The number of valid proofs (quorum) must be equal to the required messaging quorum
        if (messageQuorum[v._proof] < getRequiredMessagingQuorum(v.srcChainId)) {
            revert Error.QUORUM_NOT_REACHED();
        }

        /// @dev mint superPositions for successful deposits or remint for failed withdraws
        if (v.callbackType == uint256(CallbackType.RETURN) || v.callbackType == uint256(CallbackType.FAIL)) {
            v.multi == 1
                ? ISuperPositions(superRegistry.superPositions()).stateMultiSync(v._message)
                : ISuperPositions(superRegistry.superPositions()).stateSync(v._message);
        }

        /// @dev for initial payload processing
        if (v.callbackType == uint8(CallbackType.INIT)) {
            if (v.txType == uint8(TransactionType.WITHDRAW)) {
                returnMessage = v.multi == 1
                    ? _processMultiWithdrawal(payloadId_, v._payloadBody, v.srcSender, v.srcChainId)
                    : _processSingleWithdrawal(payloadId_, v._payloadBody, v.srcSender, v.srcChainId);
            }

            if (v.txType == uint8(TransactionType.DEPOSIT)) {
                returnMessage = v.multi == 1
                    ? _processMultiDeposit(payloadId_, v._payloadBody, v.srcSender, v.srcChainId)
                    : _processSingleDeposit(payloadId_, v._payloadBody, v.srcSender, v.srcChainId);
            }
        }

        /// @dev if deposits succeeded or some withdrawal failed, dispatch a callback
        if (returnMessage.length > 0) {
            _dispatchAcknowledgement(v.srcChainId, returnMessage, ackExtraData_);
        }

        /// @dev sets status as processed
        /// @dev check for re-entrancy & relocate if needed
        payloadTracking[payloadId_] = PayloadState.PROCESSED;
    }

    /// @dev local struct to avoid stack too deep errors
    struct RescueFailedDepositsLocalVars {
        uint64 dstChainId;
        uint64 srcChainId;
        address srcSender;
        address superForm;
    }

    /// @inheritdoc ICoreStateRegistry
    function rescueFailedDeposits(
        uint256 payloadId_,
        LiqRequest[] memory liqData_
    ) external payable override onlyProcessor {
        RescueFailedDepositsLocalVars memory v;

        uint256[] memory superFormIds = failedDeposits[payloadId_];

        uint256 l1 = superFormIds.length;
        uint256 l2 = liqData_.length;

        if (l1 == 0 || l2 == 0 || l1 != l2) {
            revert Error.INVALID_RESCUE_DATA();
        }
        uint256 _payloadHeader = payloadHeader[payloadId_];

        (, , , , v.srcSender, v.srcChainId) = _payloadHeader.decodeTxInfo();

        delete failedDeposits[payloadId_];

        v.dstChainId = superRegistry.chainId();

        for (uint256 i; i < l1; ) {
            (v.superForm, , ) = superFormIds[i].getSuperform();

            IBridgeValidator(superRegistry.getBridgeValidator(liqData_[i].bridgeId)).validateTxData(
                liqData_[i].txData,
                v.dstChainId,
                v.srcChainId,
                false, /// @dev - this acts like a withdraw where funds are bridged back to user
                v.superForm,
                v.srcSender,
                liqData_[i].token
            );

            dispatchTokens(
                superRegistry.getBridgeAddress(liqData_[i].bridgeId),
                liqData_[i].txData,
                liqData_[i].token,
                liqData_[i].amount,
                address(this), /// @dev - FIX: to send tokens from this contract when rescuing deposits, not from v.srcSender
                liqData_[i].nativeAmount,
                liqData_[i].permit2data,
                superRegistry.PERMIT2()
            );

            unchecked {
                ++i;
            }
        }
    }

    /// @dev returns the required quorum for the src chain id from super registry
    /// @param chainId is the src chain id
    /// @return the quorum configured for the chain id
    function getRequiredMessagingQuorum(uint64 chainId) public view returns (uint256) {
        return IQuorumManager(address(superRegistry)).getRequiredMessagingQuorum(chainId);
    }

    /// @dev returns array of superformIds whose deposits need to be rescued, for a given payloadId
    function getFailedDeposits(uint256 payloadId) external view returns (uint256[] memory) {
        return failedDeposits[payloadId];
    }

    /*///////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function _processMultiWithdrawal(
        uint256 payloadId_,
        bytes memory payload_,
        address srcSender_,
        uint64 srcChainId_
    ) internal returns (bytes memory) {
        InitMultiVaultData memory multiVaultData = abi.decode(payload_, (InitMultiVaultData));

        InitSingleVaultData memory singleVaultData;
        bool errors;

        for (uint256 i; i < multiVaultData.superFormIds.length; ) {
            DataLib.validateSuperformChainId(multiVaultData.superFormIds[i], superRegistry.chainId());

            singleVaultData = InitSingleVaultData({
                payloadId: multiVaultData.payloadId,
                superFormId: multiVaultData.superFormIds[i],
                amount: multiVaultData.amounts[i],
                maxSlippage: multiVaultData.maxSlippage[i],
                liqData: multiVaultData.liqData[i],
                extraFormData: abi.encode(payloadId_, i) /// @dev Store destination payloadId_ & index in extraFormData (tbd: 1-step flow doesnt need this)
            });

            (address superForm_, , ) = singleVaultData.superFormId.getSuperform();

            /// @dev a case where the withdraw req liqData has a valid token and tx data is not updated by the keeper
            if (singleVaultData.liqData.token != address(0) && singleVaultData.liqData.txData.length == 0) {
                revert Error.WITHDRAW_TX_DATA_NOT_UPDATED();
            }

            try IBaseForm(superForm_).xChainWithdrawFromVault(singleVaultData, srcSender_, srcChainId_) {
                /// @dev marks the indexes that don't require a callback re-mint of SuperPositions (successful withdraws)
                multiVaultData.amounts[i] = 0;
            } catch {
                /// @dev detect if there is at least one failed withdraw
                if (!errors) errors = true;
            }

            unchecked {
                ++i;
            }
        }

        /// @dev if at least one error happens, the shares will be re-minted for the affected superFormIds
        if (errors) {
            return
                _constructMultiReturnData(
                    srcSender_,
                    multiVaultData.payloadId,
                    TransactionType.WITHDRAW,
                    CallbackType.FAIL,
                    multiVaultData.superFormIds,
                    multiVaultData.amounts
                );
        }

        return "";
    }

    function _processMultiDeposit(
        uint256 payloadId_,
        bytes memory payload_,
        address srcSender_,
        uint64 srcChainId_
    ) internal returns (bytes memory) {
        if (payloadTracking[payloadId_] != PayloadState.UPDATED) {
            revert Error.PAYLOAD_NOT_UPDATED();
        }

        InitMultiVaultData memory multiVaultData = abi.decode(payload_, (InitMultiVaultData));

        (address[] memory superForms, , ) = DataLib.getSuperforms(multiVaultData.superFormIds);

        IERC20 underlying;
        uint256 numberOfVaults = multiVaultData.superFormIds.length;
        uint256[] memory dstAmounts = new uint256[](numberOfVaults);

        bool fulfilment;
        bool errors;

        for (uint256 i; i < numberOfVaults; ) {
            underlying = IERC20(IBaseForm(superForms[i]).getVaultAsset());

            if (underlying.balanceOf(address(this)) >= multiVaultData.amounts[i]) {
                underlying.transfer(superForms[i], multiVaultData.amounts[i]);
                LiqRequest memory emptyRequest;

                /// @dev important to validate the chainId of the superform against the chainId where this is happening
                DataLib.validateSuperformChainId(multiVaultData.superFormIds[i], superRegistry.chainId());

                /// @notice dstAmounts has same size of the number of vaults. If a given deposit fails, we are minting 0 SPs back on source (slight gas waste)
                try
                    IBaseForm(superForms[i]).xChainDepositIntoVault(
                        InitSingleVaultData({
                            payloadId: multiVaultData.payloadId,
                            superFormId: multiVaultData.superFormIds[i],
                            amount: multiVaultData.amounts[i],
                            maxSlippage: multiVaultData.maxSlippage[i],
                            liqData: emptyRequest,
                            extraFormData: multiVaultData.extraFormData
                        }),
                        srcSender_,
                        srcChainId_
                    )
                returns (uint256 dstAmount) {
                    if (!fulfilment) fulfilment = true;
                    /// @dev marks the indexes that require a callback mint of SuperPositions (successful)
                    dstAmounts[i] = dstAmount;
                } catch {
                    /// @dev if any deposit fails, we mark errors as true and add it to failedDeposits mapping for future rescuing
                    if (!errors) errors = true;

                    failedDeposits[payloadId_].push(multiVaultData.superFormIds[i]);
                }
            } else {
                revert Error.BRIDGE_TOKENS_PENDING();
            }
            unchecked {
                ++i;
            }
        }

        /// @dev issue superPositions if at least one vault deposit passed
        if (fulfilment) {
            return
                _constructMultiReturnData(
                    srcSender_,
                    multiVaultData.payloadId,
                    TransactionType.DEPOSIT,
                    CallbackType.RETURN,
                    multiVaultData.superFormIds,
                    dstAmounts
                );
        }

        if (errors) {
            emit FailedXChainDeposits(payloadId_);
        }

        return "";
    }

    function _processSingleWithdrawal(
        uint256 payloadId_,
        bytes memory payload_,
        address srcSender_,
        uint64 srcChainId_
    ) internal returns (bytes memory) {
        InitSingleVaultData memory singleVaultData = abi.decode(payload_, (InitSingleVaultData));

        DataLib.validateSuperformChainId(singleVaultData.superFormId, superRegistry.chainId());

        /// @dev a case where the withdraw req liqData has a valid token and tx data is not updated by the keeper
        if (singleVaultData.liqData.token != address(0) && singleVaultData.liqData.txData.length == 0) {
            revert Error.WITHDRAW_TX_DATA_NOT_UPDATED();
        }

        (address superForm_, , ) = singleVaultData.superFormId.getSuperform();

        /// @dev Withdraw from superform
        try IBaseForm(superForm_).xChainWithdrawFromVault(singleVaultData, srcSender_, srcChainId_) {
            // Handle the case when the external call succeeds
        } catch {
            // Handle the case when the external call reverts for whatever reason
            /// https://solidity-by-example.org/try-catch/
            return
                _constructSingleReturnData(
                    srcSender_,
                    singleVaultData.payloadId,
                    TransactionType.WITHDRAW,
                    CallbackType.FAIL,
                    singleVaultData.superFormId,
                    singleVaultData.amount
                );
        }

        return "";
    }

    function _processSingleDeposit(
        uint256 payloadId_,
        bytes memory payload_,
        address srcSender_,
        uint64 srcChainId_
    ) internal returns (bytes memory) {
        InitSingleVaultData memory singleVaultData = abi.decode(payload_, (InitSingleVaultData));
        if (payloadTracking[payloadId_] != PayloadState.UPDATED) {
            revert Error.PAYLOAD_NOT_UPDATED();
        }

        DataLib.validateSuperformChainId(singleVaultData.superFormId, superRegistry.chainId());

        (address superForm_, , ) = singleVaultData.superFormId.getSuperform();

        IERC20 underlying = IERC20(IBaseForm(superForm_).getVaultAsset());

        if (underlying.balanceOf(address(this)) >= singleVaultData.amount) {
            underlying.transfer(superForm_, singleVaultData.amount);

            /// @dev deposit to superform
            try IBaseForm(superForm_).xChainDepositIntoVault(singleVaultData, srcSender_, srcChainId_) returns (
                uint256 dstAmount
            ) {
                return
                    _constructSingleReturnData(
                        srcSender_,
                        singleVaultData.payloadId,
                        TransactionType.DEPOSIT,
                        CallbackType.RETURN,
                        singleVaultData.superFormId,
                        dstAmount
                    );
            } catch {
                /// @dev if any deposit fails, add it to failedDeposits mapping for future rescuing
                failedDeposits[payloadId_].push(singleVaultData.superFormId);

                emit FailedXChainDeposits(payloadId_);
            }
        } else {
            revert Error.BRIDGE_TOKENS_PENDING();
        }

        return "";
    }

    /// @notice depositSync and withdrawSync internal method for sending message back to the source chain
    function _constructMultiReturnData(
        address srcSender_,
        uint256 payloadId_,
        TransactionType txType,
        CallbackType returnType,
        uint256[] memory superFormIds_,
        uint256[] memory amounts
    ) internal view returns (bytes memory) {
        /// @dev Send Data to Source to issue superform positions (failed withdraws and successful deposits)
        return
            abi.encode(
                AMBMessage(
                    DataLib.packTxInfo(
                        uint8(txType),
                        uint8(returnType),
                        1,
                        superRegistry.getStateRegistryId(address(this)),
                        srcSender_,
                        superRegistry.chainId()
                    ),
                    abi.encode(ReturnMultiData(payloadId_, superFormIds_, amounts))
                )
            );
    }

    /// @notice depositSync and withdrawSync internal method for sending message back to the source chain
    function _constructSingleReturnData(
        address srcSender_,
        uint256 payloadId_,
        TransactionType txType,
        CallbackType returnType,
        uint256 superFormId_,
        uint256 amount
    ) internal view returns (bytes memory) {
        /// @dev Send Data to Source to issue superform positions (failed withdraws and successful deposits)
        return
            abi.encode(
                AMBMessage(
                    DataLib.packTxInfo(
                        uint8(txType),
                        uint8(returnType),
                        0,
                        superRegistry.getStateRegistryId(address(this)),
                        srcSender_,
                        superRegistry.chainId()
                    ),
                    abi.encode(ReturnSingleData(payloadId_, superFormId_, amount))
                )
            );
    }

    /// @dev calls the appropriate dispatch function according to the ackExtraData the keeper fed initially
    function _dispatchAcknowledgement(uint64 dstChainId_, bytes memory message_, bytes memory ackExtraData_) internal {
        AckAMBData memory ackData = abi.decode(ackExtraData_, (AckAMBData));
        uint8[] memory ambIds_ = ackData.ambIds;

        AMBExtraData memory d = abi.decode(ackData.extraData, (AMBExtraData));

        _dispatchPayload(msg.sender, ambIds_[0], dstChainId_, d.gasPerAMB[0], message_, d.extraDataPerAMB[0]);

        if (ambIds_.length > 1) {
            _dispatchProof(msg.sender, ambIds_, dstChainId_, d.gasPerAMB, message_, d.extraDataPerAMB);
        }
    }
}
