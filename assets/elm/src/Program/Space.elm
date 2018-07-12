module Program.Space exposing (..)

import Html exposing (..)
import Html.Attributes exposing (..)
import Json.Decode as Decode
import Navigation
import Process
import Task exposing (Task)
import Time exposing (second)
import Avatar exposing (personAvatar, texitar)
import Data.Group exposing (Group)
import Data.Post
import Data.Reply exposing (Reply)
import Data.Space exposing (Space)
import Data.SpaceUser
import Data.Setup as Setup
import Event
import Repo exposing (Repo)
import Page.Group
import Page.Inbox
import Page.Post
import Page.Setup.CreateGroups
import Page.Setup.InviteUsers
import Ports
import Query.SharedState
import Subscription.SpaceUserSubscription as SpaceUserSubscription
import Route exposing (Route)
import Session exposing (Session)
import Socket
import ListHelpers exposing (insertUniqueById, removeById)
import Util exposing (Lazy(..))
import ViewHelpers exposing (displayName)


main : Program Flags Model Msg
main =
    Navigation.programWithFlags UrlChanged
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }



-- MODEL


type alias Model =
    { spaceId : String
    , session : Session
    , sharedState : Lazy SharedState
    , page : Page
    , isTransitioning : Bool
    , flashNotice : Maybe String
    , repo : Repo
    }


type alias SharedState =
    Query.SharedState.Response


type Page
    = Blank
    | NotFound
    | SetupCreateGroups Page.Setup.CreateGroups.Model
    | SetupInviteUsers Page.Setup.InviteUsers.Model
    | Inbox
    | Group Page.Group.Model
    | Post Page.Post.Model


type alias Flags =
    { apiToken : String
    , spaceId : String
    }


{-| Initialize the model and kick off page navigation.

1.  Build the initial model, which begins life as a `NotBootstrapped` type.
2.  Parse the route from the location and navigate to the page.
3.  Bootstrap the application state first, then perform the queries
    required for the specific route.

-}
init : Flags -> Navigation.Location -> ( Model, Cmd Msg )
init flags location =
    flags
        |> buildModel
        |> navigateTo (Route.fromLocation location)


{-| Build the initial model, before running the page "bootstrap" query.
-}
buildModel : Flags -> Model
buildModel flags =
    Model flags.spaceId (Session.init flags.apiToken) NotLoaded Blank True Nothing Repo.init


{-| Takes a list of functions from a model to ( model, Cmd msg ) and call them in
succession. Returns a ( model, Cmd msg ), where the Cmd is a batch of accumulated
commands and the model is the original model with all mutations applied to it.
-}
updatePipeline : List (model -> ( model, Cmd msg )) -> model -> ( model, Cmd msg )
updatePipeline transforms model =
    let
        reducer transform ( model, cmds ) =
            transform model
                |> Tuple.mapSecond (\cmd -> cmd :: cmds)
    in
        List.foldr reducer ( model, [] ) transforms
            |> Tuple.mapSecond Cmd.batch



-- UPDATE


type Msg
    = -- LIFECYCLE
      UrlChanged Navigation.Location
    | SharedStateLoaded (Maybe Route) (Result Session.Error ( Session, Query.SharedState.Response ))
    | PageInitialized PageInit
      -- PAGES
    | SetupCreateGroupsMsg Page.Setup.CreateGroups.Msg
    | SetupInviteUsersMsg Page.Setup.InviteUsers.Msg
    | InboxMsg Page.Inbox.Msg
    | GroupMsg Page.Group.Msg
    | PostMsg Page.Post.Msg
      -- PORTS
    | SocketAbort Decode.Value
    | SocketStart Decode.Value
    | SocketResult Decode.Value
    | SocketError Decode.Value
    | SocketTokenUpdated Decode.Value
      -- MISC
    | SessionRefreshed (Result Session.Error Session)
    | FlashNoticeExpired


type PageInit
    = GroupInit String (Result Session.Error ( Session, Page.Group.Model ))
    | PostInit String (Result Session.Error ( Session, Page.Post.Model ))


getPage : Model -> Page
getPage model =
    model.page


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        toPage toModel toMsg subUpdate subMsg subModel =
            let
                ( newModel, newCmd ) =
                    subUpdate subMsg subModel
            in
                ( { model | page = toModel newModel }, Cmd.map toMsg newCmd )
    in
        case ( msg, model.page ) of
            ( UrlChanged location, _ ) ->
                navigateTo (Route.fromLocation location) model

            ( SharedStateLoaded maybeRoute (Ok ( session, response )), _ ) ->
                { model | sharedState = Loaded response, session = session }
                    |> updatePipeline [ navigateTo maybeRoute, setupSockets response ]

            ( SharedStateLoaded maybeRoute (Err Session.Expired), _ ) ->
                ( model, Route.toLogin )

            ( SharedStateLoaded maybeRoute (Err _), _ ) ->
                ( model, Cmd.none )

            ( InboxMsg _, _ ) ->
                -- TODO: implement this
                ( model, Cmd.none )

            ( SetupCreateGroupsMsg msg, SetupCreateGroups pageModel ) ->
                let
                    ( ( newPageModel, cmd ), session, externalMsg ) =
                        Page.Setup.CreateGroups.update msg model.session pageModel

                    newModel =
                        case externalMsg of
                            Page.Setup.CreateGroups.SetupStateChanged newState ->
                                updateSetupState newState model

                            Page.Setup.CreateGroups.NoOp ->
                                model
                in
                    ( { newModel
                        | session = session
                        , page = SetupCreateGroups newPageModel
                      }
                    , Cmd.map SetupCreateGroupsMsg cmd
                    )

            ( SetupInviteUsersMsg msg, SetupInviteUsers pageModel ) ->
                let
                    ( ( newPageModel, cmd ), session, externalMsg ) =
                        Page.Setup.InviteUsers.update msg model.session pageModel

                    newModel =
                        case externalMsg of
                            Page.Setup.InviteUsers.SetupStateChanged newState ->
                                updateSetupState newState model

                            Page.Setup.InviteUsers.NoOp ->
                                model
                in
                    ( { newModel
                        | session = session
                        , page = SetupInviteUsers newPageModel
                      }
                    , Cmd.map SetupInviteUsersMsg cmd
                    )

            ( GroupMsg msg, Group pageModel ) ->
                let
                    ( ( newPageModel, cmd ), session ) =
                        Page.Group.update msg model.repo model.session pageModel
                in
                    ( { model | session = session, page = Group newPageModel }
                    , Cmd.map GroupMsg cmd
                    )

            ( PostMsg msg, Post pageModel ) ->
                let
                    ( ( newPageModel, cmd ), session ) =
                        Page.Post.update msg model.repo model.session pageModel
                in
                    ( { model | session = session, page = Post newPageModel }
                    , Cmd.map PostMsg cmd
                    )

            ( SocketAbort value, _ ) ->
                ( model, Cmd.none )

            ( SocketStart value, _ ) ->
                ( model, Cmd.none )

            ( SocketResult value, page ) ->
                case model.sharedState of
                    Loaded sharedState ->
                        handleSocketResult value model page sharedState

                    NotLoaded ->
                        ( model, Cmd.none )

            ( SocketError value, _ ) ->
                let
                    cmd =
                        model.session
                            |> Session.fetchNewToken
                            |> Task.attempt SessionRefreshed
                in
                    ( model, cmd )

            ( SocketTokenUpdated _, _ ) ->
                ( model, Cmd.none )

            ( SessionRefreshed (Ok session), _ ) ->
                ( { model | session = session }, Ports.updateToken session.token )

            ( SessionRefreshed (Err Session.Expired), _ ) ->
                ( model, Route.toLogin )

            ( FlashNoticeExpired, _ ) ->
                ( { model | flashNotice = Nothing }, Cmd.none )

            ( PageInitialized pageInit, _ ) ->
                handlePageInit pageInit model

            ( _, _ ) ->
                -- Disregard incoming messages that arrived for the wrong page
                ( model, Cmd.none )


handleSocketResult : Decode.Value -> Model -> Page -> SharedState -> ( Model, Cmd Msg )
handleSocketResult value model page sharedState =
    case Event.decodeEvent value of
        Event.GroupBookmarked group ->
            let
                groups =
                    sharedState.bookmarkedGroups
                        |> insertUniqueById group

                newSharedState =
                    { sharedState | bookmarkedGroups = groups }
            in
                ( { model | sharedState = Loaded newSharedState }, Cmd.none )

        Event.GroupUnbookmarked group ->
            let
                groups =
                    sharedState.bookmarkedGroups
                        |> removeById group.id

                newSharedState =
                    { sharedState | bookmarkedGroups = groups }
            in
                ( { model | sharedState = Loaded newSharedState }, Cmd.none )

        Event.GroupMembershipUpdated payload ->
            case model.page of
                Group ({ group } as pageModel) ->
                    if group.id == payload.groupId then
                        let
                            ( newPageModel, cmd ) =
                                Page.Group.handleGroupMembershipUpdated payload model.session pageModel
                        in
                            ( { model | page = Group newPageModel }
                            , Cmd.map GroupMsg cmd
                            )
                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        Event.PostCreated post ->
            case model.page of
                Group ({ group } as pageModel) ->
                    if Data.Post.groupsInclude group post then
                        let
                            ( newPageModel, cmd ) =
                                Page.Group.handlePostCreated post pageModel
                        in
                            ( { model | page = Group newPageModel }
                            , Cmd.map GroupMsg cmd
                            )
                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        Event.GroupUpdated group ->
            ( handleGroupUpdated group sharedState model, Cmd.none )

        Event.ReplyCreated reply ->
            ( handleReplyCreated reply model, Cmd.none )

        Event.Unknown ->
            ( model, Cmd.none )


handlePageInit : PageInit -> Model -> ( Model, Cmd Msg )
handlePageInit pageInit model =
    case pageInit of
        GroupInit _ (Ok ( session, pageModel )) ->
            ( { model
                | page = Group pageModel
                , session = session
                , isTransitioning = False
              }
            , Page.Group.setup pageModel
                |> Cmd.map GroupMsg
            )

        GroupInit _ (Err Session.Expired) ->
            ( model, Route.toLogin )

        GroupInit _ (Err _) ->
            -- TODO: Handle other error modes
            ( model, Cmd.none )

        PostInit _ (Ok ( session, pageModel )) ->
            ( { model
                | page = Post pageModel
                , session = session
                , isTransitioning = False
              }
            , Page.Post.setup pageModel
                |> Cmd.map PostMsg
            )

        PostInit _ (Err Session.Expired) ->
            ( model, Route.toLogin )

        PostInit _ (Err _) ->
            -- TODO: Handle other error modes
            ( model, Cmd.none )


setFlashNotice : String -> Model -> ( Model, Cmd Msg )
setFlashNotice message model =
    ( { model | flashNotice = Just message }, expireFlashNotice )


expireFlashNotice : Cmd Msg
expireFlashNotice =
    Task.perform (\_ -> FlashNoticeExpired) <| Process.sleep (3 * second)


bootstrap : String -> Session -> Maybe Route -> Cmd Msg
bootstrap spaceId session maybeRoute =
    Query.SharedState.cmd spaceId session (SharedStateLoaded maybeRoute)


navigateTo : Maybe Route -> Model -> ( Model, Cmd Msg )
navigateTo maybeRoute model =
    let
        transition model toMsg task =
            ( { model | isTransitioning = True }
            , Cmd.batch
                [ teardown model.page
                , Cmd.map PageInitialized <| Task.attempt toMsg task
                ]
            )
    in
        case model.sharedState of
            NotLoaded ->
                ( model, bootstrap model.spaceId model.session maybeRoute )

            Loaded sharedState ->
                let
                    currentUser =
                        Repo.getUser model.repo sharedState.user
                in
                    case maybeRoute of
                        Nothing ->
                            ( { model | page = NotFound }, Cmd.none )

                        Just Route.Root ->
                            case currentUser.role of
                                Data.SpaceUser.Owner ->
                                    case sharedState.setupState of
                                        Setup.CreateGroups ->
                                            navigateTo (Just Route.SetupCreateGroups) model

                                        Setup.InviteUsers ->
                                            navigateTo (Just Route.SetupInviteUsers) model

                                        Setup.Complete ->
                                            navigateTo (Just Route.Inbox) model

                                _ ->
                                    navigateTo (Just Route.Inbox) model

                        Just Route.SetupCreateGroups ->
                            let
                                pageModel =
                                    Page.Setup.CreateGroups.buildModel sharedState.space.id currentUser.firstName
                            in
                                ( { model | page = SetupCreateGroups pageModel }
                                , Cmd.none
                                )

                        Just Route.SetupInviteUsers ->
                            let
                                pageModel =
                                    Page.Setup.InviteUsers.buildModel sharedState.space.id sharedState.openInvitationUrl
                            in
                                ( { model | page = SetupInviteUsers pageModel }
                                , Cmd.none
                                )

                        Just Route.Inbox ->
                            -- TODO: implement this
                            ( { model | page = Inbox }, Cmd.none )

                        Just (Route.Group groupId) ->
                            model.session
                                |> Page.Group.init currentUser sharedState.space groupId
                                |> transition model (GroupInit groupId)

                        Just (Route.Post postId) ->
                            model.session
                                |> Page.Post.init currentUser sharedState.space postId
                                |> transition model (PostInit postId)


teardown : Page -> Cmd Msg
teardown page =
    case page of
        Group pageModel ->
            Cmd.map GroupMsg (Page.Group.teardown pageModel)

        _ ->
            Cmd.none


setupSockets : SharedState -> Model -> ( Model, Cmd Msg )
setupSockets sharedState model =
    ( model, SpaceUserSubscription.subscribe sharedState.user.id )


updateSetupState : Setup.State -> Model -> Model
updateSetupState state model =
    case model.sharedState of
        NotLoaded ->
            model

        Loaded sharedState ->
            { model | sharedState = Loaded { sharedState | setupState = state } }


handleGroupUpdated : Group -> SharedState -> Model -> Model
handleGroupUpdated group sharedState ({ repo } as model) =
    { model | repo = Repo.setGroup repo group }


handleReplyCreated : Reply -> Model -> Model
handleReplyCreated reply ({ page } as model) =
    case page of
        Group pageModel ->
            let
                newPageModel =
                    Page.Group.handleReplyCreated reply pageModel
            in
                { model | page = Group newPageModel }

        Post pageModel ->
            let
                newPageModel =
                    Page.Post.handleReplyCreated reply pageModel
            in
                { model | page = Post newPageModel }

        _ ->
            model



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Ports.socketAbort SocketAbort
        , Ports.socketStart SocketStart
        , Ports.socketResult SocketResult
        , Ports.socketError SocketError
        , Ports.socketTokenUpdated SocketTokenUpdated
        , pageSubscription model
        ]


pageSubscription : Model -> Sub Msg
pageSubscription model =
    case model.page of
        Group _ ->
            Sub.map GroupMsg Page.Group.subscriptions

        Post _ ->
            Sub.map PostMsg Page.Post.subscriptions

        _ ->
            Sub.none



-- VIEW


view : Model -> Html Msg
view model =
    case model.sharedState of
        NotLoaded ->
            text ""

        Loaded sharedState ->
            div []
                [ leftSidebar sharedState model
                , pageContent model.repo sharedState model.page
                ]


leftSidebar : SharedState -> Model -> Html Msg
leftSidebar sharedState ({ page, repo } as model) =
    let
        bookmarkedGroups =
            sharedState.bookmarkedGroups
                |> Repo.getGroups repo

        currentUser =
            Repo.getUser repo sharedState.user
    in
        div [ class "fixed bg-grey-lighter border-r w-48 h-full min-h-screen p-4" ]
            [ div [ class "ml-2" ]
                [ div [ class "mb-2" ] [ spaceAvatar sharedState.space ]
                , div [ class "mb-6 font-extrabold text-lg text-dusty-blue-darker tracking-semi-tight" ] [ text sharedState.space.name ]
                ]
            , ul [ class "list-reset leading-semi-loose select-none mb-4" ]
                [ sidebarLink "Inbox" (Just Route.Inbox) page
                , sidebarLink "Everything" Nothing page
                , sidebarLink "Drafts" Nothing page
                ]
            , groupLinks bookmarkedGroups page
            , div [ class "absolute pin-b mb-4 flex" ]
                [ div [] [ personAvatar Avatar.Small currentUser ]
                , div [ class "ml-2 -mt-1 text-sm text-dusty-blue-darker leading-normal" ]
                    [ div [] [ text "Signed in as" ]
                    , div [ class "font-bold" ] [ text (displayName currentUser) ]
                    ]
                ]
            ]


groupLinks : List Group -> Page -> Html Msg
groupLinks groups currentPage =
    let
        linkify group =
            sidebarLink group.name (Just <| Route.Group group.id) currentPage

        links =
            groups
                |> List.sortBy .name
                |> List.map linkify
    in
        ul [ class "list-reset leading-semi-loose select-none" ] links


{-| Build a link for the sidebar navigation with a special indicator for the
current page. Pass Nothing for the route to make it a placeholder link.
-}
sidebarLink : String -> Maybe Route -> Page -> Html Msg
sidebarLink title maybeRoute currentPage =
    let
        link route =
            a
                [ route
                , class "ml-2 text-dusty-blue-darkest no-underline truncate"
                ]
                [ text title ]
    in
        case ( maybeRoute, routeFor currentPage ) of
            ( Just route, Just currentRoute ) ->
                if route == currentRoute then
                    li [ class "flex items-center font-bold" ]
                        [ div [ class "-ml-1 w-1 h-5 bg-turquoise rounded-full" ] []
                        , link (Route.href route)
                        ]
                else
                    li [ class "flex" ] [ link (Route.href route) ]

            ( _, _ ) ->
                li [ class "flex" ] [ link (href "#") ]


spaceAvatar : Space -> Html Msg
spaceAvatar space =
    space.name
        |> String.left 1
        |> String.toUpper
        |> texitar Avatar.Small


pageContent : Repo -> SharedState -> Page -> Html Msg
pageContent repo sharedState page =
    case page of
        SetupCreateGroups pageModel ->
            pageModel
                |> Page.Setup.CreateGroups.view
                |> Html.map SetupCreateGroupsMsg

        SetupInviteUsers pageModel ->
            pageModel
                |> Page.Setup.InviteUsers.view
                |> Html.map SetupInviteUsersMsg

        Inbox ->
            let
                featuredUsers =
                    sharedState.featuredUsers
                        |> Repo.getUsers repo
            in
                Page.Inbox.view featuredUsers
                    |> Html.map InboxMsg

        Group pageModel ->
            pageModel
                |> Page.Group.view repo
                |> Html.map GroupMsg

        Post pageModel ->
            pageModel
                |> Page.Post.view repo
                |> Html.map PostMsg

        Blank ->
            text ""

        NotFound ->
            text "404"


routeFor : Page -> Maybe Route
routeFor page =
    case page of
        Inbox ->
            Just Route.Inbox

        SetupCreateGroups _ ->
            Just Route.SetupCreateGroups

        SetupInviteUsers _ ->
            Just Route.SetupInviteUsers

        Group pageModel ->
            Just <| Route.Group pageModel.group.id

        Post pageModel ->
            Just <| Route.Post pageModel.post.id

        Blank ->
            Nothing

        NotFound ->
            Nothing