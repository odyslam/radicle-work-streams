// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

import {RolesAuthority} from "solmate/auth/authorities/RolesAuthority.sol";
import {SSTORE2} from "solmate/utils/SSTORE2.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";
import {IDripsHub} from "./IDripsHub.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
// Radicle DripsHub imports
import {ERC20Reserve} from "radicle-drips-hub/ERC20Reserve.sol";
import {ERC20DripsHub} from "radicle-drips-hub/ERC20DripsHub.sol";
import {ManagedDripsHubProxy} from "radicle-drips-hub/ManagedDripsHub.sol";
// import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";

    /*///////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/
error NoAuthorisation(
    string functionality,
    string allowed,
    uint8 workStreamType
);

contract Workstreams {
    /*///////////////////////////////////////////////////////////////
                             LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using FixedPointMathLib for uint256;
    using SafeCastLib for uint256;

    /*///////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new workstream is created.
    /// @param org The org address that created the event.
    /// @param workstreamId The Id of the workstream.
    event WorkstreamCreated(address indexed org, address workstreamId);

    event ERC20DripsHubCreated(address tokenAddress);

    /*///////////////////////////////////////////////////////////////
                             STORAGE
    //////////////////////////////////////////////////////////////*/

    uint64 public constant CYCLE_SECS = 7 days;

    address admin;

    uint256 public constant BASE_UNIT = 10e18;

    mapping(address => address) public workstreamIdToOrgAddress;

    mapping(address => ERC20DripsHub) public erc20TokensLibrary;

    IDripsHub internal daiDripsHub;

    /*///////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IDripsHub dripsHub) {
        daiDripsHub = dripsHub;
        admin = msg.sender;
    }

    /// @notice Create a new workstream with a DAI drip.
    /// @param orgAddress The address which is the owner of the workstream.
    /// @param anchor The project_id and commit hash where the workstream proposal
    /// got accepted by the Org for a particular RFP. Structure: "radicleProjectURN_at_commitHash"
    /// Example: rad:git:hnrkmzko1nps1pjogxadcmqipfxpeqn6xbeto_at_a4b88fed911c96ef5cadf60b461f7024ff967985
    /// @param workstreamMembers The initial members of the workstreams. Addresses should be ordered.
    /// @param amountsPerSecond The amount per second that each address should receive from the workstream.
    /// @param initialAmount The initial amount that the workstream creator funds the workstream with.
    /// @param permitArgs EIP712-compatible arguments struct which permits and moves funds from the workstream creator
    /// to the workstream drip.
    /// @return The workstreamId, used to retrieve information later and update the workstream.
    function createDaiWorkstream(
        address orgAddress,
        string calldata anchor,
        address[] calldata workstreamMembers,
        uint128[] calldata amountsPerSecond,
        uint128 initialAmount,
        IDripsHub.PermitArgs calldata permitArgs
    )
        external
        returns (address)
    {
        IDripsHub.DripsReceiver[] memory formatedReceivers = _receivers(
            workstreamMembers,
            amountsPerSecond
        );
        address workstreamId = fundWorkstreamDai(
            address(0),
            anchor,
            orgAddress,
            0,
            formatedReceivers,
            int128(initialAmount),
            permitArgs
        );
        workstreamIdToOrgAddress[workstreamId] = orgAddress;
        return workstreamId;
    }

    function createERC20Workstream(
        address orgAddress,
        string calldata anchor,
        address[] calldata workstreamMembers,
        uint128[] calldata amountsPerSecond,
        uint128 initialAmount,
        IDripsHub erc20Hub)
    external returns (address) {
        IDripsHub.DripsReceiver[] memory formatedReceivers = _receivers(
            workstreamMembers,
            amountsPerSecond
        );
        address workstreamId = fundWorkstreamERC20(
            address(0),
            anchor,
            orgAddress,
            0,
            formatedReceivers,
            int128(initialAmount),
            erc20Hub
        );
        workstreamIdToOrgAddress[workstreamId] = orgAddress;
        return workstreamId;
    }
    /// @notice Stores the workstream information using the SSTORE2 method. Read more information in:
    /// https://github.com/0xsequence/sstore2/ . We use the solmate implementation.
    /// @param anchor The project_id and commit hash where the workstream proposal
    /// got accepted by the Org for a particular RFP.
    /// @param workstreamType The type of Workstream. One of: 0: DAI, 1: ERC20, 2: ETH
    /// @param org The org to which the workstream belongs to.
    /// @param account The account of the drip. Every address can have different drips, one per account.
    /// Read more about accounts in: https://github.com/radicle-dev/radicle-drips-hub/blob/master/src/DripsHub.sol
    /// @param lastTimestamp The last block.timestamp at which the drip got updated.
    /// @param newBalance The new balance of the drip that will be "dripped" to the drip receivers.
    /// @param newReceivers The new receivers of the drip. It's a struct that encapsulates both the address
    /// of the receivers and the amount per second that they receive.
    /// @return workstreamId The unique identification of this workstream, required to retrieve and update it.
    function storeWorkstream(
        string memory anchor,
        uint8 workstreamType,
        address org,
        uint256 account,
        uint64 lastTimestamp,
        int128 newBalance,
        IDripsHub.DripsReceiver[] memory newReceivers
    ) internal returns (address) {
        return
            SSTORE2.write(
                abi.encode(
                    anchor,
                    workstreamType,
                    org,
                    account,
                    lastTimestamp,
                    newBalance,
                    newReceivers
                )
            );
    }

    /// @notice Load the workstream from the SSTORE2 storage. Read more about this in storeWorkstream.
    /// @param key The address that is used as a key to load the data from storage. It returns the data passed with
    /// storeWorkstream.
    function loadWorkstream(address key)
        public
        view
        returns (
            string memory,
            uint8,
            address,
            uint256,
            uint64,
            uint128,
            IDripsHub.DripsReceiver[] memory
        )
    {
        return
            abi.decode(
                SSTORE2.read(key),
                (
                    string,
                    uint8,
                    address,
                    uint256,
                    uint64,
                    uint128,
                    IDripsHub.DripsReceiver[]
                )
            );
    }

    /// @notice Fund a workstream. If it's the first time, it also serves as initialization of the workstream object.
    /// @param workstreamId The workstream Id is required to retrieve information about the workstream.
    /// @param anchor The projectId and commit hash of the proposal to the project's canonical repository.
    /// @param org The org owner of the workstream.
    /// @param account The org's account the workstream's drip in the main DripsHub smart contract.
    /// @param newReceivers The updated struct of the receivers and their respective amount-per-second.
    /// @param amount The new amount that will fund this workstream's drip.
    /// @param permitArgs The permitArgs used to permit and move the required DAI from the orgAddress to the drip.
    /// @return It returns the new workstream Id for this particular workstream.
    function fundWorkstreamDai(
        address workstreamId,
        string memory anchor,
        address org,
        uint256 account,
        IDripsHub.DripsReceiver[] memory newReceivers,
        int128 amount,
        IDripsHub.PermitArgs calldata permitArgs
    ) public returns (address) {
        if (workstreamId == address(0)) {
            IDripsHub.DripsReceiver[] memory oldReceivers;
            daiDripsHub.setDripsAndPermit(
                account,
                0,
                0,
                oldReceivers,
                amount,
                newReceivers,
                permitArgs
            );
        } else {
            _internalFundDai(
                workstreamId,
                amount,
                newReceivers,
                permitArgs
            );
        }
        return
            storeWorkstream(
                anchor,
                1,
                org,
                account,
                uint64(block.timestamp),
                amount,
                newReceivers
            );
    }

    function fundWorkstreamERC20(
        address workstreamId,
        string memory anchor,
        address org,
        uint256 account,
        IDripsHub.DripsReceiver[] memory newReceivers,
        int128 amount,
        IDripsHub erc20Hub
    ) public returns (address) {
        if (workstreamId == address(0)) {
            IDripsHub.DripsReceiver[] memory oldReceivers;
            erc20Hub.setDrips(
                account,
                0,
                0,
                oldReceivers,
                amount,
                newReceivers
            );
        } else {
            _internalFundERC20(
                workstreamId,
                amount,
                newReceivers
            );
        }
        return
            storeWorkstream(
                anchor,
                1,
                org,
                account,
                uint64(block.timestamp),
                amount,
                newReceivers
            );
    }
    /// @notice Internal function that is used to break up fundWorkstreamDai and bypass the 'stack too deep' error.
    /// For the parameters read the fundWorkstreamDai function.
    function _internalFundDai(
        address workstreamId,
        int128 amount,
        IDripsHub.DripsReceiver[] memory newReceivers,
        IDripsHub.PermitArgs calldata permitArgs
    ) internal {
        IDripsHub.DripsReceiver[] memory oldReceivers;
        uint64 lastTimestamp;
        uint128 balance;
        address org;
        uint256 account;
        (
            ,
            ,
            org,
            account,
            lastTimestamp,
            balance,
            oldReceivers
        ) = loadWorkstream(workstreamId);
        account++;
        daiDripsHub.setDripsAndPermit(
            account,
            lastTimestamp,
            balance,
            oldReceivers,
            amount,
            newReceivers,
            permitArgs
        );
    }

    function _internalFundERC20(
        address workstreamId,
        int128 amount,
        IDripsHub.DripsReceiver[] memory newReceivers
    ) internal {
        IDripsHub.DripsReceiver[] memory oldReceivers;
        uint64 lastTimestamp;
        uint128 balance;
        address org;
        uint256 account;
        (
            ,
            ,
            org,
            account,
            lastTimestamp,
            balance,
            oldReceivers
        ) = loadWorkstream(workstreamId);
        account++;
        daiDripsHub.setDrips(
            account,
            lastTimestamp,
            balance,
            oldReceivers,
            amount,
            newReceivers
        );
    }

    function addERC20Token(address erc20Token)
        external
    {
        require(address(erc20TokensLibrary[erc20Token]) == address(0), "Workstreams::addERC20Token::erc20_token_already_added");
        IERC20 erc20 = IERC20(erc20Token);
        ERC20DripsHub hubLogic = new ERC20DripsHub(CYCLE_SECS, erc20);
        ManagedDripsHubProxy proxy = new ManagedDripsHubProxy(hubLogic, admin);
        ERC20DripsHub hub = ERC20DripsHub(address(proxy));
        erc20TokensLibrary[erc20Token] = hub;
        ERC20Reserve reserve = new ERC20Reserve(erc20, admin, address(hub));
        hub.setReserve(reserve);
        emit ERC20DripsHubCreated(erc20Token);
    }


    /// @notice Internal function that constructs the receivers struct from two arrays of receivers and
    /// amounts-per-second.
    /// @param receiversAddresses An ordered array of addresses.
    /// @param amountsPerSecond Amount of funds that should be driped to the corresponding address
    /// defined in the receversAddresses parameter.
    /// @return formatedReceivers The final struct that is cominbes the params and
    /// is required by the DripsHub smart contract.
    function _receivers(
        address[] calldata receiversAddresses,
        uint128[] memory amountsPerSecond
    ) internal view returns (IDripsHub.DripsReceiver[] memory) {
        IDripsHub.DripsReceiver[]
            memory formatedReceivers = new IDripsHub.DripsReceiver[](
                receiversAddresses.length
            );
        for (uint256 i; i < receiversAddresses.length; i++) {
            formatedReceivers[i] = IDripsHub.DripsReceiver(
                receiversAddresses[i],
                amountsPerSecond[i]
            );
        }
        return formatedReceivers;
    }
}
