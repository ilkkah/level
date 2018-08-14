module Component.Mention
    exposing
        ( Model
        , Msg(..)
        , fragment
        , decoder
        , setup
        , teardown
        , update
        , handleReplyCreated
        , view
        )

import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Component.Post
import Connection exposing (Connection)
import Data.Mention as Mention exposing (Mention)
import Data.Post as Post exposing (Post)
import Data.Reply as Reply exposing (Reply)
import Data.SpaceUser as SpaceUser exposing (SpaceUser)
import Date exposing (Date)
import GraphQL exposing (Fragment)
import Icons
import Json.Decode as Decode exposing (Decoder, field, string)
import ListHelpers
import Mutation.DismissMentions as DismissMentions
import Repo exposing (Repo)
import Route
import Session exposing (Session)
import Task
import View.Helpers exposing (displayName)


-- MODEL


type alias Model =
    { id : String
    , mention : Mention
    , post : Component.Post.Model
    }


fragment : Fragment
fragment =
    GraphQL.fragment
        """
        fragment MentionFields on Mention {
          id
          post {
            ...PostFields
            replies(last: 3) {
              ...ReplyConnectionFields
            }
          }
          mentioners {
            ...SpaceUserFields
          }
          lastOccurredAt
        }
        """
        [ Post.fragment
        , Connection.fragment "ReplyConnection" Reply.fragment
        , SpaceUser.fragment
        ]


decoder : Decoder Model
decoder =
    Decode.map3 Model
        (field "id" string)
        (Mention.decoder)
        (field "post" (Component.Post.decoder Component.Post.Feed))



-- LIFECYCLE


setup : Model -> Cmd Msg
setup model =
    Component.Post.setup model.post
        |> Cmd.map PostComponentMsg


teardown : Model -> Cmd Msg
teardown model =
    Component.Post.teardown model.post
        |> Cmd.map PostComponentMsg



-- UPDATE


type Msg
    = PostComponentMsg Component.Post.Msg
    | DismissClicked String
    | Dismissed String (Result Session.Error ( Session, DismissMentions.Response ))


update : Msg -> String -> Session -> Model -> ( ( Model, Cmd Msg ), Session )
update msg spaceId session model =
    case msg of
        PostComponentMsg msg ->
            let
                ( ( newPost, cmd ), newSession ) =
                    Component.Post.update msg spaceId session model.post
            in
                ( ( { model | post = newPost }
                  , Cmd.map PostComponentMsg cmd
                  )
                , newSession
                )

        DismissClicked id ->
            let
                cmd =
                    session
                        |> DismissMentions.request spaceId id
                        |> Task.attempt (Dismissed id)
            in
                ( ( model, cmd ), session )

        Dismissed id (Ok ( session, _ )) ->
            -- TODO
            ( ( model, Cmd.none ), session )

        Dismissed _ (Err Session.Expired) ->
            redirectToLogin session model

        Dismissed _ (Err _) ->
            ( ( model, Cmd.none ), session )


redirectToLogin : Session -> Model -> ( ( Model, Cmd Msg ), Session )
redirectToLogin session model =
    ( ( model, Route.toLogin ), session )



-- EVENT HANDLERS


handleReplyCreated : Reply -> Model -> ( Model, Cmd Msg )
handleReplyCreated reply model =
    let
        ( newPost, cmd ) =
            Component.Post.handleReplyCreated reply model.post
    in
        ( { model | post = newPost }
        , Cmd.map PostComponentMsg cmd
        )



-- VIEW


view : Repo -> SpaceUser -> Date -> Model -> Html Msg
view repo currentUser now { post, mention } =
    let
        mentionData =
            Mention.getCachedData mention
    in
        div [ class "flex py-4" ]
            [ div [ class "flex-0 pr-3" ]
                [ button [ class "flex items-center", onClick (DismissClicked post.id) ] [ Icons.square ]
                ]
            , div [ class "flex-1" ]
                [ div [ class "mb-3 text-sm font-extrabold text-dusty-blue" ]
                    [ text <| mentionersSummary repo mentionData.mentioners ]
                , postView repo currentUser now post
                ]
            ]


postView : Repo -> SpaceUser -> Date -> Component.Post.Model -> Html Msg
postView repo currentUser now postComponent =
    postComponent
        |> Component.Post.view repo currentUser now
        |> Html.map PostComponentMsg


mentionersSummary : Repo -> List SpaceUser -> String
mentionersSummary repo mentioners =
    case mentioners of
        firstUser :: others ->
            let
                firstUserName =
                    firstUser
                        |> Repo.getSpaceUser repo
                        |> displayName

                otherCount =
                    ListHelpers.size others
            in
                if otherCount == 0 then
                    firstUserName ++ " mentioned you"
                else
                    firstUserName ++ " and " ++ (toString otherCount) ++ " others mentioned you"

        [] ->
            ""