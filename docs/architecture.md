# Architecture

This mono-repo is the host for the Maybe You're Not Lost project. The architetcure is explained via various purposes of the application.

All containerized pieces of the application are hosted in Microsoft Azure:

- Front End (Vite + React + TypeScript, Container App)
- Encouragements API (.NET 10 Minimal API, Container App)
- Encouragements DB (Postgres, Azure Databse for Postgres Flexible Server)
- Contacts API (.NET 10 Minimal API, Container App)
- Contacts DB (Postgres, Azure Databse for Postgres Flexible Server)

## Authorization

TODO

## General Purpose

The purpose of this website, as of now, has a couple of overarching goals:

- Gather and store encouragement that can be given to others.
- Give visitors the ability to recieve encouragement on a cadence via text.
  - Texts have not yet been implemented.

## Giving Encouragement

A user can give encouragement by sending it from the front end. On a submit:

- The encouragement is posted to the Encouragement API via the `/encouragements` endpoint.
- If successful, it returns the identity of the created resource.

## Recieving Encouragement

A user can recieve encouragement by giving us their cell phone number to store. On a submit:

- The phone number, as a contact, is posted to the Contacts API via the `/contacts` endpoint.
- If successful, it returns the identity of the created resource.
