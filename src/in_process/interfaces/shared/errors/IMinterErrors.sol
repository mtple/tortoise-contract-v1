// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IMinterErrors {
    error CallerNotInProcessCreator1155();
    error MinterContractAlreadyExists();
    error MinterContractDoesNotExist();

    error SaleEnded();
    error SaleHasNotStarted();
    error WrongValueSent();
    error InvalidMerkleProof(address mintTo, bytes32[] merkleProof, bytes32 merkleRoot);
}
