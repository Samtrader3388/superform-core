// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

/// @title ISuperFormFactory
/// @author ZeroPoint Labs
/// @notice Interface for SuperForm Factory
interface ISuperFormFactory {
    /*///////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    /// @dev emitted when a new form beacon is entered into the factory
    /// @param formImplementation is the address of the new form implementation
    /// @param beacon is the address of the beacon
    /// @param formBeaconId is the id of the new form beacon
    event FormBeaconAdded(address indexed formImplementation, address indexed beacon, uint256 indexed formBeaconId);

    /// @dev emitted when a new SuperForm is created
    /// @param formBeaconId is the id of the form beacon
    /// @param vault is the address of the vault
    /// @param superFormId is the id of the superform
    /// @param superForm is the address of the superform
    event SuperFormCreated(
        uint256 indexed formBeaconId,
        address indexed vault,
        uint256 indexed superFormId,
        address superForm
    );

    /// @dev emitted when a new SuperRegistry is set
    /// @param superRegistry is the address of the super registry
    event SuperRegistrySet(address indexed superRegistry);

    /*///////////////////////////////////////////////////////////////
                        External Write Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev allows an admin to add a FormBeacon to the factory
    /// @param formImplementation_ is the address of a form implementation
    /// @param formBeaconId_ is the id of the form beacon (generated off-chain and equal in all chains)
    /// @param salt_ is the salt for create2
    function addFormBeacon(
        address formImplementation_,
        uint32 formBeaconId_,
        bytes32 salt_
    ) external returns (address beacon);

    /// @dev allows an admin to add Form Beacons to the factory
    /// @param formImplementations_ are the address of form implementaions
    /// @param formBeaconIds_ are the to-be ids of the form beacons
    /// @param salt_ is the salt for create2
    function addFormBeacons(
        address[] memory formImplementations_,
        uint32[] memory formBeaconIds_,
        bytes32 salt_
    ) external;

    /// @dev To add new vaults to Form implementations, fusing them together into SuperForms
    /// @param formBeaconId_ is the form beacon we want to attach the vault to
    /// @param vault_ is the address of the vault
    /// @return superFormId_ is the id of the created superform
    /// @return superForm_ is the address of the created superform
    function createSuperForm(
        uint32 formBeaconId_,
        address vault_
    ) external returns (uint256 superFormId_, address superForm_);

    /// @dev To add new vaults to Form implementations, fusing them together into SuperForms
    /// @param formBeaconIds_ are the form beacon ids we want to attach the vaults to
    /// @param vaults_ are the addresses of the vaults
    /// @return superFormIds_ are the id of the created superforms
    /// @return superForms_ are the addresses of the created superforms
    function createSuperForms(
        uint32[] memory formBeaconIds_,
        address[] memory vaults_
    ) external returns (uint256[] memory superFormIds_, address[] memory superForms_);

    /// @dev to synchronize superforms added to different chains using factory registry
    /// @param data_ is the cross-chain superform id
    function stateSync(bytes memory data_) external payable;

    /// @dev allows an admin to update the logic of a form
    /// @param formBeaconId_ is the id of the form beacon
    /// @param newFormLogic_ is the address of the new form logic
    function updateFormBeaconLogic(uint32 formBeaconId_, address newFormLogic_) external;

    /// @dev allows an admin to change the status of a form
    /// @param formBeaconId_ is the id of the form beacon
    /// @param status_ is the new status
    /// @param extraData_ is optional & passed when broadcasting of status is needed
    function changeFormBeaconPauseStatus(uint32 formBeaconId_, bool status_, bytes memory extraData_) external payable;

    /*///////////////////////////////////////////////////////////////
                            View Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev returns the address of a form beacon
    /// @param formBeaconId_ is the id of the beacon form
    /// @return formBeacon_ is the address of the beacon form
    function getFormBeacon(uint32 formBeaconId_) external view returns (address formBeacon_);

    /// @dev returns the paused status of form beacon
    /// @param formBeaconId_ is the id of the beacon form
    /// @return paused_ is the current paused status of the form beacon
    function isFormBeaconPaused(uint32 formBeaconId_) external view returns (bool paused_);

    /// @dev returns the address of a superform
    /// @param superFormId_ is the id of the superform
    /// @return superForm_ is the address of the superform
    /// @return formBeaconId_ is the id of the form beacon
    /// @return chainId_ is the chain id
    function getSuperForm(
        uint256 superFormId_
    ) external pure returns (address superForm_, uint32 formBeaconId_, uint64 chainId_);

    /// @dev Reverse query of getSuperForm, returns all superforms for a given vault
    /// @param vault_ is the address of a vault
    /// @return superFormIds_ is the id of the superform
    /// @return superForms_ is the address of the superform
    function getAllSuperFormsFromVault(
        address vault_
    ) external view returns (uint256[] memory superFormIds_, address[] memory superForms_);

    /// @dev Returns all SuperForms
    /// @return superFormIds_ is the id of the superform
    /// @return vaults_ is the address of the vault
    function getAllSuperForms() external view returns (uint256[] memory superFormIds_, address[] memory vaults_);

    /// @dev returns the number of forms
    /// @return forms_ is the number of forms
    function getFormCount() external view returns (uint256 forms_);

    /// @dev returns the number of superforms
    /// @return superForms_ is the number of superforms
    function getSuperFormCount() external view returns (uint256 superForms_);
}
