// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/KeeperCompatible.sol";

// 确认owner
import {ConfirmedOwner} from "@chainlink/contracts@1.1.1/src/v0.8/shared/access/ConfirmedOwner.sol";

import {VRFV2WrapperConsumerBase} from "@chainlink/contracts@1.1.1/src/v0.8/vrf/VRFV2WrapperConsumerBase.sol";
import {LinkTokenInterface} from "@chainlink/contracts@1.1.1/src/v0.8/shared/interfaces/LinkTokenInterface.sol";

contract Payroll is VRFV2WrapperConsumerBase, ConfirmedOwner {
    address[] public employees;

    mapping(address => uint256) public dailyWages;

    mapping(address => uint256) public employeeWaitWages;

    uint256 public thisMonthTotalWages;

    address public winnerEmployee;
    uint256 public winnerBonus;

    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(
        uint256 requestId,
        uint256[] randomWords,
        uint256 payment
    );

    struct RequestStatus {
        uint256 paid; // amount paid in link
        bool fulfilled; // whether the request has been successfully fulfilled
        uint256[] randomWords;
    }
    mapping(uint256 => RequestStatus) public s_requests; /* requestId --> requestStatus */

    // past requests Id.
    uint256[] public requestIds;
    uint256 public lastRequestId;

    uint32 callbackGasLimit = 100000;

    // The default is 3, but you can set this higher.
    uint16 requestConfirmations = 3;

    // For this example, retrieve 2 random values in one request.
    // Cannot exceed VRFV2Wrapper.getConfig().maxNumWords.
    uint32 numWords = 1;

    // Address LINK - hardcoded for Sepolia
    address linkAddress = 0x779877A7B0D9E8603169DdbD7836e478b4624789;

    // address WRAPPER - hardcoded for Sepolia
    address wrapperAddress = 0xab18414CD93297B0d12ac29E63Ca20f515b3DB46;

    constructor()
        ConfirmedOwner(msg.sender) // owner = msg.sender;
        VRFV2WrapperConsumerBase(linkAddress, wrapperAddress)
    {}

    function addEmployee(address employee, uint256 dailyWage) public onlyOwner {
        employees.push(employee);
        dailyWages[employee] = dailyWage;
    }

    function getDailyWages()
        public
        view
        onlyOwner
        returns (address[] memory, uint256[] memory)
    {
        uint256 length = employees.length;
        address[] memory employeeAddresses = new address[](length);
        uint256[] memory wages = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            address employee = employees[i];
            employeeAddresses[i] = employee;
            wages[i] = dailyWages[employee];
        }

        return (employeeAddresses, wages);
    }

    function calculateTotalDailyWages() public {
        uint256 totalDailyWages = 0;

        for (uint256 i = 0; i < employees.length; i++) {
            address employee = employees[i];
            totalDailyWages += dailyWages[employee];
        }
        thisMonthTotalWages += totalDailyWages;
    }

    function transferTotalDailyWages() public payable onlyOwner {
        require(
            thisMonthTotalWages != 0,
            "Wages payable today are to be calculated"
        );
        require(
            msg.value == thisMonthTotalWages,
            "Sent value is not equal to the total daily wages"
        );
        for (uint256 i = 0; i < employees.length; i++) {
            address employee = employees[i];
            uint256 amount = employeeWaitWages[employee];
            payable(employee).transfer(amount);
            employeeWaitWages[employee] = 0;
        }
        thisMonthTotalWages = 0;
    }

    function isBalanceAtLeastThisMonthTotalWages() public view returns (bool) {
        return address(this).balance >= thisMonthTotalWages;
    }

    function requestRandomWords()
        external
        onlyOwner
        returns (uint256 requestId)
    {
        requestId = requestRandomness(
            callbackGasLimit,
            requestConfirmations,
            numWords
        );
        s_requests[requestId] = RequestStatus({
            paid: VRF_V2_WRAPPER.calculateRequestPrice(callbackGasLimit),
            randomWords: new uint256[](0),
            fulfilled: false
        });
        requestIds.push(requestId);
        lastRequestId = requestId;
        emit RequestSent(requestId, numWords);
        return requestId;
    }

    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {
        require(s_requests[_requestId].paid > 0, "request not found");
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;

        uint256 winnerIndex = _randomWords[0] % employees.length;
        winnerEmployee = employees[winnerIndex];
        uint256 bonus = (_randomWords[0] % 10) + 1;
        winnerBonus = bonus;

        emit RequestFulfilled(
            _requestId,
            _randomWords,
            s_requests[_requestId].paid
        );
    }

    function getRequestStatus(uint256 _requestId)
        external
        view
        returns (
            uint256 paid,
            bool fulfilled,
            uint256[] memory randomWords
        )
    {
        require(s_requests[_requestId].paid > 0, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.paid, request.fulfilled, request.randomWords);
    }

    function withdrawLink() public onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(linkAddress);
        require(
            link.transfer(msg.sender, link.balanceOf(address(this))),
            "Unable to transfer"
        );
    }

    function getLatestRandomNumber() public view returns (uint256) {
        require(lastRequestId != 0, "No random number requested yet");
        require(
            s_requests[lastRequestId].fulfilled,
            "Random number not fulfilled yet"
        );
        return s_requests[lastRequestId].randomWords[0];
    }
}
